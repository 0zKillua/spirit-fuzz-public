// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {PriceGrid} from "../../../src/libraries/PriceGrid.sol";

/// Lead-authored (S7), prize-b201485d, thread-e406bd3d.
///
/// THE HINGE: OloBookTakes.sol:470, `quote = sum * OloMath.pow10(low - 43)`, UNCHECKED. Every prior session flagged this
/// as the one concrete value-creation/overflow concern that was reasoned "unreachable" but NEVER executed at the
/// extreme. The second reader called "coverage of decade 73 and of amounts near 2^112 essentially zero." The S6
/// predecessor's MultiDecadeStress reached only decade 55 with tiny amounts (<=1e4 base). These tests push to the GRID'S
/// TRUE TOP: tick = PriceGrid.MAX_TICK (decade 73, P = 999_999e30 ~ 1e36 quote wei per base wei) with a base fill near
/// the 2^112 input cap, i.e. the LARGEST real quote any reachable take can produce (~5e69 ~ 2^232), the closest the
/// contract can get to the 2^256 wrap.
///
/// WHAT MUST HOLD (the reading these tests make executable):
///  - sum is held below SUM_LIMIT = 2^235 by the walk; at a high `low` the real quote is sum * 10^(low-43), and because
///    a base-mode take fills at most `amount` < 2^112 base at a per-unit price < 2^120, the real quote is below 2^232 <
///    2^256. The SUM_LIMIT bound is SLACK precisely because a large `low` forces a small `sum`. The multiply at :470
///    therefore never wraps; the take either succeeds with the exact whole quote, or reverts AmountOverflow at a
///    documented guard. It must NEVER return a wrapped (tiny) quote that hands the makers' base to the taker for free.
///  - No value is created: makers + pot are paid no more than the taker paid in; the book stays solvent; everyone
///    leaves with only dust in the contract's favour.
contract TopOfGridStressTest is OloBase {
    uint256 constant MAX_TICK = PriceGrid.MAX_TICK; // 66_599_999: decade 73, mantissa 999_999
    uint256 constant D60 = 60 * 900_000; // decade 60 bottom (mantissa 100_000)

    function setUp() public {
        _deploy(); // fee 50 ppm, global maker share 10_000 (maker takes the whole fee)
    }

    /// A single ask at the very top tick, escrowing a base amount near the 2^112 input cap, bought whole by the taker.
    /// This drives :470 at low = 73 with the largest single-order sum the inputs allow. The quote is ~5e69 wei (~2^232):
    /// if the unchecked multiply wrapped, the taker would pay far less than that for the base, and either solvency or the
    /// "taker paid what it was told" check would fail.
    function test_buy_at_top_tick_near_max_amount_conserves() public {
        uint256 amount = 5e33; // < 2^112 (5.19e33); the ask escrows toUnits(amount) <= this
        address a = _bigAsk(address(0x7300), MAX_TICK, amount);

        // the taker needs ~amount * P ~ 5e69 quote wei in its wallet; fund it well past that
        quote.mint(taker, 1e71);

        bytes memory seg = OloOps.poolList(OloOps.poolEntry(posOf[a], MAX_TICK));

        uint256 takerQuoteBefore = quote.balanceOf(taker);
        uint256 takerBaseBefore = base.balanceOf(taker);
        vm.prank(taker);
        (uint256 baseAmount, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(true, amount, OloOps.WALLET)));

        // the whole ask filled: baseAmount is the escrowed base (units * 10^q, <= amount)
        assertGt(baseAmount, 0, "something filled");
        assertEq(base.balanceOf(taker) - takerBaseBefore, baseAmount, "taker received the base it filled");
        // the quote the taker actually paid equals what take reported, and it is the real ~1e69-scale number, NOT a
        // tiny wrapped value: assert it is at least baseAmount (price per base wei >> 1 at decade 73)
        uint256 paid = takerQuoteBefore - quote.balanceOf(taker);
        assertEq(paid, quoteAmount, "taker paid exactly the quote take reported");
        assertGt(quoteAmount, baseAmount, "quote at decade 73 dwarfs base: no wrap to a tiny value");
        // the exact expected quote (whole at decade 73): base * mantissa * 10^30, fee on it rounded up
        uint256 expectedQuote = PriceGrid.quoteUp(baseAmount, MAX_TICK);
        assertEq(quoteAmount, expectedQuote + _feeUp(expectedQuote), "quote+fee is the exact top-of-grid value");
        _solvent();

        // the maker claims its fills to its WALLET (proceeds ~5e69 overflow a 2^128 account; the book routes a maker's
        // proceeds past the account cap through the wallet)
        uint256 makerQuoteWalletBefore = quote.balanceOf(a);
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], OloOps.WALLET)));
        uint256 makerGot = quote.balanceOf(a) - makerQuoteWalletBefore;
        _solvent();

        // conservation: maker proceeds + pot never exceed what the taker paid
        uint256 potGot = _pot(quote);
        assertLe(makerGot + potGot, quoteAmount, "makers + pot <= taker paid (no value created)");
        // the maker is paid the floor quote + its full fee share (share 10_000): at least the floor quote
        assertGe(makerGot, PriceGrid.quoteDown(baseAmount, MAX_TICK), "maker paid at least its floor proceeds");

        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    /// Two asks at the top region in DIFFERENT high decades (73 then 60), met out of order so the walk's `_accrue` runs
    /// its higher-decade branch (sum += v * 10^(decade-low)) after low is pinned at 60 by the later, lower fill. This is
    /// the multi-order, multi-high-decade stress on :470 and on _accrue's SUM_LIMIT guard, the surface with "essentially
    /// zero" coverage.
    function test_buy_across_two_high_decades_conserves() public {
        uint256 amt73 = 3e33;
        uint256 amt60 = 2e33;
        address a73 = _bigAsk(address(0x7301), MAX_TICK, amt73);
        address a60 = _bigAsk(address(0x6001), D60 + 123, amt60);

        quote.mint(taker, 1e71);

        // list 73 first then 60: the walk meets 73 (low=73), then 60 (< low) -> _accrue scales the sum down to low=60
        bytes memory seg = OloOps.poolList(
            bytes.concat(OloOps.poolEntry(posOf[a73], MAX_TICK), OloOps.poolEntry(posOf[a60], D60 + 123))
        );

        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        (uint256 baseAmount, uint256 quoteAmount) = book.take(
            OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(true, amt73 + amt60, OloOps.WALLET))
        );

        assertGt(baseAmount, 0, "filled");
        uint256 paid = takerQuoteBefore - quote.balanceOf(taker);
        assertEq(paid, quoteAmount, "taker paid exactly the quote take reported");
        // both high-decade fills are whole; the reported quote must equal the sum of the two exact per-order quotes,
        // rounded once up over the exact total (a buy ceils). Since both decades are >= 43 the per-order quotes are
        // whole, so the single-rounding total equals their exact sum; fee is ceil on that.
        _solvent();

        uint256 mq73Before = quote.balanceOf(a73);
        uint256 mq60Before = quote.balanceOf(a60);
        vm.prank(a73);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a73], OloOps.WALLET)));
        vm.prank(a60);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a60], OloOps.WALLET)));
        uint256 makersGot = (quote.balanceOf(a73) - mq73Before) + (quote.balanceOf(a60) - mq60Before);
        _solvent();

        uint256 potGot = _pot(quote);
        assertLe(makersGot + potGot, quoteAmount, "makers + pot <= taker paid (no value created)");

        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    /// The fee of `quote` quote wei at the fixture's 50 ppm, rounded up (OloMath.divUp), as _finishTake computes it.
    function _feeUp(uint256 q) internal pure returns (uint256) {
        uint256 ppm = 50;
        uint256 v = q * ppm;
        uint256 out = v / 1_000_000;
        return v % 1_000_000 == 0 ? out : out + 1;
    }

    /// A maker funded with a large base balance, resting `amount` base wei as an ask at `tick`. Registered in makers[]
    /// (via _makerAt) and posOf/tickOf so _everyoneLeaves and the take list helpers see it.
    function _bigAsk(address who, uint256 tick, uint256 amount) internal returns (address a) {
        a = _makerAt(who); // deposits 1e24 of each; mints 1e30 of each; approves max
        base.mint(a, amount + 1); // enough extra base to escrow the big ask
        vm.startPrank(a);
        book.deposit(address(base), amount); // base account now 1e24 + amount (< 2^128)
        uint32 pos = _pos();
        posOf[a] = pos;
        tickOf[a] = tick;
        book.place(OloOps.key(c), OloOps.placeW(false, tick, amount, pos, 0));
        vm.stopPrank();
    }
}
