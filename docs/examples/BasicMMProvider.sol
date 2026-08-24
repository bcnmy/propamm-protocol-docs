// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMMProvider} from "../../interfaces/IMMProvider.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title BasicMMProvider - minimal MM inventory contract
///
/// @notice Canonical MM-provider template. Holds inventory, exposes a single `executeSwap` hook,
///         gates it on `msg.sender == approvedExecutor`. No signature verification, no price logic,
///         no pair registry - those live in `PropAMMExecutor` and the orchestrator.
///
/// @dev Onboarding checklist for an MM operator:
///        1. Deploy this contract. Constructor takes `signer_` (the address whose private key
///           will sign board messages off-chain) and `executor_` (the `PropAMMExecutor` address
///           this provider trusts).
///        2. Fund the contract with `tokenOut` inventory for every pair you'll quote.
///        3. Connect your off-chain signer to the orchestrator and stream signed board messages.
///        4. Rotate via `setApprovedExecutor` or `setSigner` (one tx each) if needed.
///
///      Security boundary: only `approvedExecutor` may call `executeSwap`. The MM controls
///      `approvedExecutor` via the owner key. If the trusted executor is ever compromised, the MM
///      can rotate to a new executor in a single tx.
contract BasicMMProvider is IMMProvider, Ownable {
    // ============ Storage ============

    /// @notice MM's board signing address. Read by the router per fill to look up the
    ///         anchor and verify signatures. Rotate by calling `setSigner`.
    address public override signer;

    /// @notice The IExecutor contract authorized to call `executeSwap`. Set by the owner.
    address public approvedExecutor;

    // ============ Errors ============

    error NotApprovedExecutor();
    error ZeroAddress();

    // ============ Events ============

    event ApprovedExecutorSet(address indexed previous, address indexed current);
    event SignerSet(address indexed previous, address indexed current);
    event InventoryWithdrawn(address indexed token, uint256 amount, address indexed to);

    // ============ Constructor ============

    /// @param signer_   MM's board signing address. EOA for ECDSA MMs; contract for EIP-1271 MMs.
    /// @param executor_ IExecutor contract authorized to drain inventory via `executeSwap`.
    /// @param owner_    Initial owner - controls rotations + withdrawals.
    constructor(address signer_, address executor_, address owner_) {
        if (signer_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        _initializeOwner(owner_);
        signer = signer_;
        approvedExecutor = executor_;
        emit SignerSet(address(0), signer_);
        emit ApprovedExecutorSet(address(0), executor_);
    }

    // ============ Owner controls ============

    /// @notice Rotate the trusted executor. Useful for upgrading to a new executor deploy or
    ///         responding to a compromised executor.
    function setApprovedExecutor(address newExecutor) external onlyOwner {
        emit ApprovedExecutorSet(approvedExecutor, newExecutor);
        approvedExecutor = newExecutor;
    }

    /// @notice Rotate the MM's board message signing key. Subsequent fills must use the new key's
    ///         signed board messages - the router reads `signer()` per fill.
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerSet(signer, newSigner);
        signer = newSigner;
    }

    /// @notice Owner-only inventory withdrawal (top-up reversal, shutdown, etc.).
    function withdraw(address token, uint256 amount, address to) external onlyOwner {
        SafeTransferLib.safeTransfer(token, to, amount);
        emit InventoryWithdrawn(token, amount, to);
    }

    // ============ IMMProvider ============

    /// @inheritdoc IMMProvider
    /// @dev Minimal MM: applies no drift on top of anchor price. Real MMs with curves should
    ///      override this to return the actual amount their `executeSwap` would deliver.
    function previewSwap(
        address,
        /*tokenIn*/
        address,
        /*tokenOut*/
        uint256 amountIn,
        uint256 anchorPrice
    )
        external
        pure
        override
        returns (uint256 amountOut)
    {
        return (amountIn * anchorPrice) / 1e18;
    }

    /// @inheritdoc IMMProvider
    /// @dev Basic MM: delivers `amountIn * anchorPrice / 1e18`, no curve. The MM owns this math.
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 anchorPrice,
        uint256 amountOut,
        address receiver
    ) external override returns (uint256 delivered) {
        if (msg.sender != approvedExecutor) revert NotApprovedExecutor();
        // Pull tokenIn from the executor (it pre-approved this contract on first encounter).
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        // Compute our own output from the fresh anchor price and release it from inventory.
        delivered = amountOut; // exact swept output from the executor
        SafeTransferLib.safeTransfer(tokenOut, receiver, delivered);
    }

    /// @notice Allow receiving native ETH (e.g. if WETH withdraw lands here during a future
    ///         native-aware variant).
    receive() external payable {}
}
