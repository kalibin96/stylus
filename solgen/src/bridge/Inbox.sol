//
// Copyright 2021, Offchain Labs, Inc. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
//

pragma solidity ^0.8.4;

import "./IInbox.sol";
import "./IBridge.sol";

import "./Messages.sol";
import "../libraries/AddressAliasHelper.sol";
import "../libraries/DelegateCallAware.sol";

import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Bridge.sol";

/**
* @title Inbox for user and contract originated messages
* @notice Messages created via this inbox are enqueued in the delayed accumulator
* to await inclusion in the SequencerInbox
*/
contract Inbox is DelegateCallAware, PausableUpgradeable, IInbox {
    uint8 internal constant ETH_TRANSFER = 0;
    uint8 internal constant L2_MSG = 3;
    uint8 internal constant L1MessageType_L2FundedByL1 = 7;
    uint8 internal constant L1MessageType_submitRetryableTx = 9;

    uint8 internal constant L2MessageType_unsignedEOATx = 0;
    uint8 internal constant L2MessageType_unsignedContractTx = 1;

    // 90% of Geth's 128KB tx size limit, leaving ~13KB for proving
    uint256 public constant MAX_DATA_SIZE = 117964;

    IBridge public override bridge;

    modifier onlyOwner() {
        // the rollup contract owns the bridge
        address bridgeowner = Bridge(address(bridge)).owner();
        // we want to validate the owner of the rollup
        //address owner = RollupBase(rollup).owner();
        if(msg.sender != bridgeowner) revert NotOwner(msg.sender, bridgeowner);
        _;
    }

    /// @notice pauses all inbox functionality
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice unpauses all inbox functionality
    function unpause() external onlyOwner {
        _unpause();
    }

    function initialize(IBridge _bridge) external initializer onlyDelegated {
        if(address(bridge) != address(0)) revert AlreadyInit();
        bridge = _bridge;
        __Pausable_init();
    }

    /// @dev function to be called one time during the inbox upgrade process
    /// this is used to fix the storage slots
    function postUpgradeInit(IBridge _bridge) external initializer onlyDelegated onlyProxyOwner {
        uint8 slotsToWipe = 3;
        for(uint8 i = 0; i<slotsToWipe; i++) {
            assembly {
                sstore(i, 0)
            }
        }
        bridge = _bridge;
        __Pausable_init();
    }

    /**
     * @notice Send a generic L2 message to the chain
     * @dev This method is an optimization to avoid having to emit the entirety of the messageData in a log. Instead validators are expected to be able to parse the data from the transaction's input
     * @param messageData Data of the message being sent
     */
    function sendL2MessageFromOrigin(bytes calldata messageData)
        external
        whenNotPaused
        returns (uint256)
    {
        // solhint-disable-next-line avoid-tx-origin
        if(msg.sender != tx.origin) revert NotOrigin();
        if(messageData.length > MAX_DATA_SIZE) revert DataTooLarge(messageData.length, MAX_DATA_SIZE);
        uint256 msgNum = deliverToBridge(L2_MSG, msg.sender, keccak256(messageData));
        emit InboxMessageDeliveredFromOrigin(msgNum);
        return msgNum;
    }

    /**
     * @notice Send a generic L2 message to the chain
     * @dev This method can be used to send any type of message that doesn't require L1 validation
     * @param messageData Data of the message being sent
     */
    function sendL2Message(bytes calldata messageData)
        external
        override
        whenNotPaused
        returns (uint256)
    {
        if(messageData.length > MAX_DATA_SIZE) revert DataTooLarge(messageData.length, MAX_DATA_SIZE);
        uint256 msgNum = deliverToBridge(L2_MSG, msg.sender, keccak256(messageData));
        emit InboxMessageDelivered(msgNum, messageData);
        return msgNum;
    }

    function sendL1FundedUnsignedTransaction(
        uint256 maxGas,
        uint256 gasPriceBid,
        uint256 nonce,
        address destAddr,
        bytes calldata data
    ) external payable virtual override whenNotPaused returns (uint256) {
        return
            _deliverMessage(
                L1MessageType_L2FundedByL1,
                msg.sender,
                abi.encodePacked(
                    L2MessageType_unsignedEOATx,
                    maxGas,
                    gasPriceBid,
                    nonce,
                    uint256(uint160(bytes20(destAddr))),
                    msg.value,
                    data
                )
            );
    }

    function sendL1FundedContractTransaction(
        uint256 maxGas,
        uint256 gasPriceBid,
        address destAddr,
        bytes calldata data
    ) external payable virtual override whenNotPaused returns (uint256) {
        return
            _deliverMessage(
                L1MessageType_L2FundedByL1,
                msg.sender,
                abi.encodePacked(
                    L2MessageType_unsignedContractTx,
                    maxGas,
                    gasPriceBid,
                    uint256(uint160(bytes20(destAddr))),
                    msg.value,
                    data
                )
            );
    }

    function sendUnsignedTransaction(
        uint256 maxGas,
        uint256 gasPriceBid,
        uint256 nonce,
        address destAddr,
        uint256 amount,
        bytes calldata data
    ) external virtual override whenNotPaused returns (uint256) {
        return
            _deliverMessage(
                L2_MSG,
                msg.sender,
                abi.encodePacked(
                    L2MessageType_unsignedEOATx,
                    maxGas,
                    gasPriceBid,
                    nonce,
                    uint256(uint160(bytes20(destAddr))),
                    amount,
                    data
                )
            );
    }

    function sendContractTransaction(
        uint256 maxGas,
        uint256 gasPriceBid,
        address destAddr,
        uint256 amount,
        bytes calldata data
    ) external virtual override whenNotPaused returns (uint256) {
        return
            _deliverMessage(
                L2_MSG,
                msg.sender,
                abi.encodePacked(
                    L2MessageType_unsignedContractTx,
                    maxGas,
                    gasPriceBid,
                    uint256(uint160(bytes20(destAddr))),
                    amount,
                    data
                )
            );
    }

    /// @notice deposit eth from L1 to L2
    /// @dev this function should not be called inside contract constructors
    function depositEth(uint256 maxSubmissionCost)
        external
        payable
        virtual
        override
        whenNotPaused
        returns (uint256)
    {
        address sender = msg.sender;
        address destinationAddress = msg.sender;

        if (!AddressUpgradeable.isContract(sender) && tx.origin == msg.sender) {
            // isContract check fails if this function is called during a contract's constructor.
            // We don't adjust the address for calls coming from L1 contracts since their addresses get remapped
            // If the caller is an EOA, we adjust the address.
            // This is needed because unsigned messages to the L2 (such as retryables)
            // have the L1 sender address mapped.
            // Here we preemptively reverse the mapping for EOAs so deposits work as expected
            sender = AddressAliasHelper.undoL1ToL2Alias(sender);
        } else {
            destinationAddress = AddressAliasHelper.applyL1ToL2Alias(destinationAddress);
        }

        return
            _deliverMessage(
                L1MessageType_submitRetryableTx,
                sender,
                abi.encodePacked(
                    // the beneficiary and other refund addresses don't get rewritten by arb-os
                    // so we use the original msg.sender value
                    uint256(uint160(bytes20(destinationAddress))),
                    uint256(0),
                    msg.value,
                    maxSubmissionCost,
                    uint256(uint160(bytes20(destinationAddress))),
                    uint256(uint160(bytes20(destinationAddress))),
                    uint256(0),
                    uint256(0),
                    uint256(0),
                    ""
                )
            );
    }

    /**
     * @notice Put a message in the L2 inbox that can be reexecuted for some fixed amount of time if it reverts
     * @dev Advanced usage only (does not rewrite aliases for excessFeeRefundAddress and callValueRefundAddress). createRetryableTicket method is the recommended standard.
     * @param destAddr destination L2 contract address
     * @param l2CallValue call value for retryable L2 message
     * @param  maxSubmissionCost Max gas deducted from user's L2 balance to cover base submission fee
     * @param excessFeeRefundAddress maxgas x gasprice - execution cost gets credited here on L2 balance
     * @param callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
     * @param maxGas Max gas deducted from user's L2 balance to cover L2 execution
     * @param gasPriceBid price bid for L2 execution
     * @param data ABI encoded data of L2 message
     * @return unique id for retryable transaction (keccak256(requestID, uint(0) )
     */
    function createRetryableTicketNoRefundAliasRewrite(
        address destAddr,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes calldata data
    ) public payable virtual whenNotPaused returns (uint256) {

        return
            _deliverMessage(
                L1MessageType_submitRetryableTx,
                msg.sender,
                abi.encodePacked(
                    uint256(uint160(bytes20(destAddr))),
                    l2CallValue,
                    msg.value,
                    maxSubmissionCost,
                    uint256(uint160(bytes20(excessFeeRefundAddress))),
                    uint256(uint160(bytes20(callValueRefundAddress))),
                    maxGas,
                    gasPriceBid,
                    data.length,
                    data
                )
            );
    }

    /**
     * @notice Put a message in the L2 inbox that can be reexecuted for some fixed amount of time if it reverts
     * @dev all msg.value will deposited to callValueRefundAddress on L2
     * @param destAddr destination L2 contract address
     * @param l2CallValue call value for retryable L2 message
     * @param  maxSubmissionCost Max gas deducted from user's L2 balance to cover base submission fee
     * @param excessFeeRefundAddress maxgas x gasprice - execution cost gets credited here on L2 balance
     * @param callValueRefundAddress l2Callvalue gets credited here on L2 if retryable txn times out or gets cancelled
     * @param maxGas Max gas deducted from user's L2 balance to cover L2 execution
     * @param gasPriceBid price bid for L2 execution
     * @param data ABI encoded data of L2 message
     * @return unique id for retryable transaction (keccak256(requestID, uint(0) )
     */
    function createRetryableTicket(
        address destAddr,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 maxGas,
        uint256 gasPriceBid,
        bytes calldata data
    ) external payable virtual override whenNotPaused returns (uint256) {
        // if a refund address is a contract, we apply the alias to it
        // so that it can access its funds on the L2
        // since the beneficiary and other refund addresses don't get rewritten by arb-os
        if (AddressUpgradeable.isContract(excessFeeRefundAddress)) {
            excessFeeRefundAddress = AddressAliasHelper.applyL1ToL2Alias(excessFeeRefundAddress);
        }
        if (AddressUpgradeable.isContract(callValueRefundAddress)) {
            // this is the beneficiary. be careful since this is the address that can cancel the retryable in the L2
            callValueRefundAddress = AddressAliasHelper.applyL1ToL2Alias(callValueRefundAddress);
        }

        return
            createRetryableTicketNoRefundAliasRewrite(
                destAddr,
                l2CallValue,
                maxSubmissionCost,
                excessFeeRefundAddress,
                callValueRefundAddress,
                maxGas,
                gasPriceBid,
                data
            );
    }

    function _deliverMessage(
        uint8 _kind,
        address _sender,
        bytes memory _messageData
    ) internal returns (uint256) {
        if(_messageData.length > MAX_DATA_SIZE) revert DataTooLarge(_messageData.length, MAX_DATA_SIZE);
        uint256 msgNum = deliverToBridge(_kind, _sender, keccak256(_messageData));
        emit InboxMessageDelivered(msgNum, _messageData);
        return msgNum;
    }

    function deliverToBridge(
        uint8 kind,
        address sender,
        bytes32 messageDataHash
    ) internal returns (uint256) {
        return bridge.enqueueDelayedMessage{ value: msg.value }(kind, sender, messageDataHash);
    }
}
