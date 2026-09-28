// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMMProvider} from "../../interfaces/IMMProvider.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @notice The inventory side of a maker's vault as this provider uses it: token balances the vault
///         holds, and an ERC-20 allowance the vault grants to its configured router.
interface IRouterVault {
    function router() external view returns (address);
}

/// @title RouterVaultProvider
/// @notice Connects a maker's existing inventory vault to `PropAMMExecutor` without moving the
///         inventory. The vault keeps the tokens and names this contract as its router; on each
///         fill this contract takes the maker's output from the vault straight to the receiver and
///         sends the taker's input straight into the vault. Nothing rests here between fills.
///
/// @dev Built for vaults that trust one router through an ERC-20 allowance, the pattern the
///      maker's pAMM already uses on Ethereum: `setRouter(provider, tokens)`, then
///      `approve(token, amount)` per token, both from the vault's admin. No vault code changes.
///
///      Security boundary, same as `BasicMMProvider`:
///        - only `approvedExecutor` may call `executeSwap`;
///        - the executor enforces the maker's signed board, expiry and meter on every fill;
///        - the maker bounds exposure with the allowance it grants and can cut it to zero, or
///          point the vault's router elsewhere, in one transaction.
contract RouterVaultProvider is IMMProvider, Ownable {
    using SafeTransferLib for address;

    /// @notice The vault holding the maker's inventory.
    address public immutable vault;

    /// @inheritdoc IMMProvider
    address public override signer;

    /// @notice The executor allowed to call `executeSwap`.
    address public approvedExecutor;

    error NotApprovedExecutor();
    error ZeroAddress();
    error NotVaultRouter();

    event ApprovedExecutorSet(address indexed previous, address indexed current);
    event SignerSet(address indexed previous, address indexed current);

    /// @param vault_    The maker's inventory vault.
    /// @param signer_   The key that signs the maker's board messages.
    /// @param executor_ The `PropAMMExecutor` this provider trusts.
    /// @param owner_    The maker's admin, controls rotations.
    constructor(address vault_, address signer_, address executor_, address owner_) {
        if (vault_ == address(0) || signer_ == address(0) || executor_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        _initializeOwner(owner_);
        signer = signer_;
        approvedExecutor = executor_;
        emit SignerSet(address(0), signer_);
        emit ApprovedExecutorSet(address(0), executor_);
    }

    function setApprovedExecutor(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) revert ZeroAddress();
        emit ApprovedExecutorSet(approvedExecutor, newExecutor);
        approvedExecutor = newExecutor;
    }

    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerSet(signer, newSigner);
        signer = newSigner;
    }

    /// @notice Returns tokens sent here by mistake. Inventory lives in the vault, never here.
    function rescue(address token, uint256 amount, address to) external onlyOwner {
        token.safeTransfer(to, amount);
    }

    /// @inheritdoc IMMProvider
    /// @dev Delivers the board's output. Declines (returns 0) when the vault is not routing to this
    ///      contract or cannot cover the output, so the network skips the maker instead of building
    ///      a route that would revert.
    function previewSwap(address, address tokenOut, uint256 amountIn, uint256 anchorPrice)
        external
        view
        override
        returns (uint256 amountOut)
    {
        amountOut = (amountIn * anchorPrice) / 1e18;
        if (amountOut > available(tokenOut)) return 0;
    }

    /// @notice How much of `token` a fill can take from the vault right now: the smaller of the
    ///         vault's balance and its allowance to this contract, zero when it routes elsewhere.
    function available(address token) public view returns (uint256) {
        if (IRouterVault(vault).router() != address(this)) return 0;
        uint256 bal = _balanceOf(token, vault);
        uint256 allowed = _allowance(token, vault, address(this));
        return bal < allowed ? bal : allowed;
    }

    /// @inheritdoc IMMProvider
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256, /* anchorPrice */
        uint256 amountOut,
        address receiver
    ) external override returns (uint256 delivered) {
        if (msg.sender != approvedExecutor) revert NotApprovedExecutor();
        if (IRouterVault(vault).router() != address(this)) revert NotVaultRouter();
        // The taker's input goes straight into the vault (the executor approved this contract).
        tokenIn.safeTransferFrom(msg.sender, vault, amountIn);
        // The maker's output comes straight from the vault, within the allowance it granted.
        tokenOut.safeTransferFrom(vault, receiver, amountOut);
        delivered = amountOut;
    }

    function _balanceOf(address token, address who) private view returns (uint256 b) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0x70a08231, who));
        if (ok && ret.length >= 32) b = abi.decode(ret, (uint256));
    }

    function _allowance(address token, address from, address spender) private view returns (uint256 a) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(0xdd62ed3e, from, spender));
        if (ok && ret.length >= 32) a = abi.decode(ret, (uint256));
    }
}
