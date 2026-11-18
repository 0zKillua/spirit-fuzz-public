// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {PriceGrid} from "../../../src/libraries/PriceGrid.sol";
import {IOloBookBase} from "../../../src/interfaces/IOloBookBase.sol";

/// Lead-authored (S8), prize-b201485d.
///
/// THE HINGE (never executed): the second reader flagged `_restsAt`/`_worthMin` with a `takeThenRest` limitTick in the
/// gap (MAX_TICK, 2^26) — "decade-74 valuation" — as an unexecuted boundary. The `restW` helper allows any limitTick
/// < 2^26 (67_108_863), but the grid ends at MAX_TICK = 66_599_999 (decade 73). The REST_TICK field is 26 bits, so a
/// taker CAN encode a tick in decade 74 (66_600_000 .. 67_108_863), off the grid.
///
/// OloBook.sol:265-266 says `_restsAt` does NOT check the tick: an off-grid tick is VALUED like any other (and the doc
/// claims a tick below 2^26 is decade 74 at most, so `_worthMin`'s products stay below 2^240 — no overflow), and the
/// guard lives at OloBook.sol:231: `if (rest != 0 && !k.makerTick(tick)) revert TickOutOfRange();`. The risk, if the
/// guard were wrong or the valuation overflowed, is a resting maker order priced in a non-existent decade — a mis-valued
/// order the book would settle against, i.e. value creation / insolvency.
///
/// These tests EXECUTE that boundary on the SELL-rest path (leftover rests as an ASK, escrow in base, which the fixture
/// taker can afford — unlike a buy-rest bid at decade 73, whose quote escrow is astronomically large):
///   - MAX_TICK (66_599_999, decade 73): a valid maker tick, the rest DOES place, book stays solvent.
///   - MAX_TICK + 1 (66_600_000, decade 74): off-grid, leftover present -> TickOutOfRange, nothing placed.
///   - 2^26 - 1 (67_108_863, the very top of the 26-bit field, deep in decade 74): off-grid -> TickOutOfRange.
///   - off-grid limit but the take fills EVERYTHING (rest == 0): the limit is never checked -> no revert (confirms the
///     guard is `rest != 0 && ...`, not unconditional, matching the doc "a take that filled everything ... needs no
///     limit").
/// The decade-74 valuation inside `_restsAt` runs on every revert case (it is called at :230, before the :231 guard),
/// so these also prove that valuation does not overflow.
contract RestTickBoundaryTest is OloBase {
    uint256 constant MAX_TICK = PriceGrid.MAX_TICK; // 66_599_999: decade 73, mantissa 999_999
    uint256 constant OFF_D74 = 66_600_000; // decade 74, mantissa 100_000: the first tick past the grid
    uint256 constant OFF_TOP = (1 << 26) - 1; // 67_108_863: top of the 26-bit field, deep in decade 74
    uint8 constant SETTLE_WALLET = 0x02; // SettleFlags.WALLET (distinct from the take-mode WALLET = 0x01)

    function setUp() public {
        _deploy(); // fee 50 ppm, global maker share 10_000, spacing 1 (every tick a maker tick), minQuote 1
    }

    /// The valid edge: a sell with no fills whose leftover rests as an ask at MAX_TICK (the last real tick). The rest
    /// places (escrow = the base, pulled from the taker's wallet), the book is solvent, and cancelling refunds it whole.
    function test_maxtick_sell_rest_places_and_is_solvent() public {
        uint256 amount = 1e9; // base wei to sell; < 2^30 so q = 0, stored = 1e9, escrow = 1e9 base (affordable)
        uint32 restPos = _pos();
        bytes memory emptySeg = OloOps.poolList(""); // no orders to fill -> the whole amount is leftover

        uint256 takerBaseBefore = base.balanceOf(taker);
        vm.prank(taker);
        (,,, uint256 restOrderId) = book.takeThenRest(
            OloOps.key(c), emptySeg, OloOps.tagW(c, OloOps.restW(false, amount, MAX_TICK, OloOps.WALLET, restPos))
        );
        // the leftover rested as an ask at MAX_TICK: an order id was returned and the escrow left the wallet
        assertTrue(restOrderId != 0, "the leftover rested");
        assertEq(takerBaseBefore - base.balanceOf(taker), amount, "exactly the escrow was pulled from the wallet");
        _solvent();

        // cancel the rested ask: the base escrow comes back to the wallet, the book stays solvent, the taker is whole
        vm.prank(taker);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(restPos, SETTLE_WALLET)));
        _solvent();
        assertEq(base.balanceOf(taker), takerBaseBefore, "the taker got the whole escrow back: no value lost or created");
    }

    /// The first off-grid tick (decade 74). A leftover is present, so OloBook.sol:231 reverts TickOutOfRange — the
    /// resting order is never placed at a non-existent price. The decade-74 valuation at :230 ran first without overflow.
    function test_decade74_limit_with_leftover_reverts() public {
        uint256 amount = 1e9;
        uint32 restPos = _pos();
        bytes memory emptySeg = OloOps.poolList("");

        vm.prank(taker);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.takeThenRest(
            OloOps.key(c), emptySeg, OloOps.tagW(c, OloOps.restW(false, amount, OFF_D74, OloOps.WALLET, restPos))
        );
    }

    /// The very top of the 26-bit tick field (67_108_863), far into decade 74: still off-grid, still refused with a
    /// leftover. This is the largest tick the field can hold, the extreme of the second reader's concern.
    function test_top_of_field_limit_with_leftover_reverts() public {
        uint256 amount = 1e9;
        uint32 restPos = _pos();
        bytes memory emptySeg = OloOps.poolList("");

        vm.prank(taker);
        vm.expectRevert(IOloBookBase.TickOutOfRange.selector);
        book.takeThenRest(
            OloOps.key(c), emptySeg, OloOps.tagW(c, OloOps.restW(false, amount, OFF_TOP, OloOps.WALLET, restPos))
        );
    }

    /// The complement: an off-grid limitTick is harmless when the take fills EVERYTHING, because `rest == 0` short-
    /// circuits the guard (OloBook.sol:231 `rest != 0 && ...`). A bid rests; the sell consumes it exactly; nothing is
    /// left to rest, so the decade-74 limit is never checked and the call succeeds and stays solvent.
    function test_offgrid_limit_is_ignored_when_nothing_rests() public {
        uint256 lot = 1e6; // base wei
        uint256 t = 38 * 900_000 + 500; // a real bid tick (decade 38)
        address b = _plain(t, true, lot); // a resting bid wanting `lot` base

        uint32 restPos = _pos();
        bytes memory seg = OloOps.poolList(OloOps.poolEntry(posOf[b], t));

        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        // sell exactly `lot` into the bid: the bid is fully consumed, rest == 0, OFF_TOP never checked
        (uint256 baseAmount,, uint256 rested,) = book.takeThenRest(
            OloOps.key(c), seg, OloOps.tagW(c, OloOps.restW(false, lot, OFF_TOP, OloOps.WALLET, restPos))
        );
        assertEq(baseAmount, lot, "the whole sell filled the bid");
        assertEq(rested, 0, "nothing rested, so the off-grid limit was never checked");
        assertGt(quote.balanceOf(taker), takerQuoteBefore, "the taker received quote for the sell");
        _solvent();

        // the bid maker cancels to recover its remaining escrow; everyone leaves with only dust left behind
        vm.prank(b);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[b], SETTLE_WALLET)));
        _solvent();
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }
}
