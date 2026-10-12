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
///
///      `approvedExecutor` and `signer` are both immutable. The vault's allowance is spendable by
///      whoever this contract trusts and at whatever price its signer signs, so an owner able to
///      name a new executor or a new signer could name itself and pull the whole allowance. A new
///      executor generation or a signer rotation is therefore a new provider plus `setRouter`
///      from the vault admin, which also revokes this one's allowance and darkens its boards in
///      the same transaction. The owner keeps only `rescue`, for tokens sent to this contract.
///
///      `available` and `previewSwap` fail closed: if the vault's `router()` reverts or returns
///      malformed data they report 0, so the executor never reads a failed check as unlimited
///      inventory.
contract RouterVaultProvider is IMMProvider, Ownable {
    using SafeTransferLib for address;

    /// @notice The vault holding the maker's inventory.
    address public immutable vault;

    /// @inheritdoc IMMProvider
    address public immutable override signer;

    /// @notice The executor allowed to call `executeSwap`. Fixed for this provider's lifetime.
    address public immutable approvedExecutor;

    error NotApprovedExecutor();
    error ZeroAddress();
    error NotVaultRouter();

    /// @param vault_    The maker's inventory vault.
    /// @param signer_   The key that signs the maker's board messages.
    /// @param executor_ The `PropAMMExecutor` this provider trusts.
    /// @param owner_    The maker's admin; may only rescue tokens sent to this contract.
    constructor(address vault_, address signer_, address executor_, address owner_) {
        if (vault_ == address(0) || signer_ == address(0) || executor_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        _initializeOwner(owner_);
        signer = signer_;
        approvedExecutor = executor_;
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
        if (!_isVaultRouter()) return 0;
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
        if (!_isVaultRouter()) revert NotVaultRouter();
        // The taker's input goes straight into the vault (the executor approved this contract).
        tokenIn.safeTransferFrom(msg.sender, vault, amountIn);
        // The maker's output comes straight from the vault, within the allowance it granted.
        tokenOut.safeTransferFrom(vault, receiver, amountOut);
        delivered = amountOut;
    }

    /// @dev True only when the vault's `router()` returns this contract. A revert, short return
    ///      data or a non-address word reads as false, so callers fail closed. The word is compared
    ///      as a uint256 because decoding it as an address would revert on dirty upper bits.
    function _isVaultRouter() private view returns (bool) {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSelector(IRouterVault.router.selector));
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) == uint256(uint160(address(this)));
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
