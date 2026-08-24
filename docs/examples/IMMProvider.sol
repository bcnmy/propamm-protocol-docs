// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IMMProvider
/// @notice The interface a maker's inventory contract implements to be filled by `PropAMMExecutor`.
///
/// @dev The provider's job is to hold `tokenOut` inventory and release it for `tokenIn` when the
///      executor asks. Pricing and routing decisions live off-chain and in the executor's board.
///
///      Trust gate:
///        - The provider stores `approvedExecutor` (set by its owner). `executeSwap` must require
///          `msg.sender == approvedExecutor`. This is the entire security boundary on the
///          provider side: no other contract can move inventory.
///        - The maker's signing key (returned by `signer()`) signs board messages off-chain and
///          is checked by the executor. The provider itself never verifies signatures. The
///          executor reads `signer()` on every fill and refuses a board whose maker is not the
///          provider's signer, so rotating the signer rotates that binding.
///
///      Amounts:
///        - The executor passes `amountIn`, the sweep's average price and the exact swept
///          `amountOut`; the provider pulls `amountIn` from the executor, delivers its output of
///          `tokenOut` to `receiver` and returns what it delivered.
///        - The executor imposes no output cap. The taker's floor (a router's or an intent's
///          `minAmountOut`) is enforced at settlement, so an under-priced fill reverts rather than
///          shortchanging the taker.
interface IMMProvider {
    /// @notice The address whose key signs the maker's board messages. An EOA for ECDSA makers,
    ///         or a contract for EIP-1271 makers (multisig, threshold signatures, custom
    ///         verifiers). The executor reads it on every fill.
    function signer() external view returns (address);

    /// @notice Off-chain quote used by the network while building hosted routes. A maker whose
    ///         provider applies its own dynamics on top of the board (drift, a curve, inventory
    ///         skew) implements this so the route's `minAmountOut` reflects what `executeSwap`
    ///         will deliver.
    ///
    /// @dev Must be a view with no state writes and should be cheap, since it is called
    ///      concurrently during route fan-out.
    ///
    ///      A provider that delivers exactly the board's output returns
    ///      `(amountIn * anchorPrice) / 1e18`; `BasicMMProvider` does that.
    ///
    ///      A provider with its own curve computes its actual `executeSwap` output here so route
    ///      building reflects what the taker receives.
    ///
    ///      Returning 0 declines the quote (insufficient inventory, paused, trader refused); the
    ///      network skips the maker for that route.
    ///
    /// @param tokenIn     Token the provider receives (WETH for native intents).
    /// @param tokenOut    Token the provider sends (WETH for native intents).
    /// @param amountIn    Hypothetical input size.
    /// @param anchorPrice The board's price for this size, 1e18-scaled tokenOut per tokenIn. The
    ///                    provider may use it as a baseline, apply its own dynamics, or ignore it.
    /// @return amountOut  What `executeSwap` would deliver for these inputs in the current block.
    function previewSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 anchorPrice)
        external
        view
        returns (uint256 amountOut);

    /// @notice Atomic fill: pull `amountIn` of `tokenIn` from `msg.sender` (the executor), deliver
    ///         the provider's output of `tokenOut` from inventory to `receiver`, return the amount.
    ///
    /// @dev Implementations must enforce `msg.sender == approvedExecutor` and revert otherwise; a
    ///      silent no-op is not safe.
    ///
    ///      `amountOut` is the exact order-book sweep total the executor computed across the
    ///      board's tranches, so a provider that follows the board delivers precisely that.
    ///      `anchorPrice` is the sweep's volume-weighted average, for providers that shape an
    ///      order on an external venue from a price; a basic provider ignores it. The executor
    ///      imposes no cap; the taker's floor is enforced at settlement.
    ///
    /// @param tokenIn     Token being received (the executor substitutes WETH for native).
    /// @param tokenOut    Token being sent (the executor substitutes WETH for native).
    /// @param amountIn    Exact amount of `tokenIn` to pull from `msg.sender`.
    /// @param anchorPrice The sweep's average price, 1e18-scaled tokenOut per tokenIn.
    /// @param amountOut   The exact swept output the provider is expected to deliver.
    /// @param receiver    Destination of `tokenOut`.
    /// @return delivered  Amount of `tokenOut` actually sent to `receiver`.
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 anchorPrice,
        uint256 amountOut,
        address receiver
    ) external returns (uint256 delivered);
}
