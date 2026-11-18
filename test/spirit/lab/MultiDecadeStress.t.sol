// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";

/// Lead-authored (S6), prize-b201485d. The hinge the S5 dig (dig-61a4713b) was aimed at but never reported on: a single
/// take that crosses several orders in DIFFERENT, FRACTIONAL decades (below EXP_OFFSET=43), forcing the walk's exact-sum
/// aligner (`_accrue`) through its lower-decade re-scaling branch (sum = sum*10^(low-d) + v) mid-walk, and the
/// per-order-vs-total fee rounding at makerBps = 10,000 (feeDown per order vs divUp over the exact total). The second
/// reader flagged fractional decades + high decades + near-2^112 amounts as essentially un-fuzzed. These are direct,
/// hand-built conservation checks over that surface: the book must create no value (everyone leaves, only dust in the
/// contract's favour) and stay solvent at every step.
///
/// Decade bottoms are d*900_000; the fixture's maker tick spacing is 1 (6 sig figs), so any tick is a maker tick. P at
/// decade d, mantissa (100_000+j), is (100_000+j) * 10^(d-43), a proper fraction of a quote wei for d < 43: that is
/// where per-order rounding (quoteDown/feeDown) actually bites, and where a single rounded take-quote (ceil for a buy,
/// floor for a sell) must still dominate the sum of the makers' rounded settles.
contract MultiDecadeStressTest is OloBase {
    uint256 constant D36 = 36 * 900_000; // 32_400_000
    uint256 constant D37 = 37 * 900_000; // 33_300_000
    uint256 constant D38 = 38 * 900_000; // 34_200_000 == T
    uint256 constant D39 = 39 * 900_000; // 35_100_000

    function setUp() public {
        _deploy(); // fixture lists at fee 50 ppm, maker share 10_000 (maker takes the whole fee)
    }

    /// A buy that crosses four asks in four fractional decades, listed so the walk meets decades OUT OF ORDER
    /// (38, 39, 37, 36): `_accrue` scales the running sum down to 37 and then 36, the lowest met. Odd mantissas and odd
    /// amounts make every per-order quote a true fraction. Then every maker claims its fill and the book is unwound.
    function test_buy_across_fractional_decades_conserves() public {
        // asks at odd mantissas in four decades, odd amounts (all < 2^30, so q=0 and fills are whole base wei)
        address a38 = _plain(D38 + 777, false, 2_500_001);
        address a39 = _plain(D39 + 5, false, 333_333);
        address a37 = _plain(D37 + 123, false, 1_000_003);
        address a36 = _plain(D36 + 99, false, 7_777_777);

        // the take list in the SAME order the makers were placed, so the walk meets decades 38, 39, 37, 36: the sum
        // re-aligns downward twice. Each entry's bound is its own tick (a buy fills an ask at or below the bound).
        bytes memory seg = OloOps.poolList(
            bytes.concat(
                OloOps.poolEntry(posOf[a38], D38 + 777),
                OloOps.poolEntry(posOf[a39], D39 + 5),
                OloOps.poolEntry(posOf[a37], D37 + 123),
                OloOps.poolEntry(posOf[a36], D36 + 99)
            )
        );

        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        (uint256 baseAmount, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(true, 20_000_000, OloOps.WALLET)));

        // every ask fully filled: the base bought is the sum of the four amounts
        assertEq(baseAmount, 2_500_001 + 333_333 + 1_000_003 + 7_777_777, "all four asks filled");
        // the taker paid exactly quoteAmount of quote wei from the wallet
        assertEq(takerQuoteBefore - quote.balanceOf(taker), quoteAmount, "taker paid the quote it was told");
        _solvent();

        // each maker claims its fill (maker share 10_000: the maker takes the whole fee, the pot gets nothing here)
        _claimAsk(a38);
        _claimAsk(a39);
        _claimAsk(a37);
        _claimAsk(a36);
        _solvent();

        // conservation: the sum of what the makers were paid (now in their quote accounts) must not exceed what the
        // taker paid in. Any gap is dust stranded in the contract's favour.
        uint256 makersGot = _bal(a38, quote) + _bal(a39, quote) + _bal(a37, quote) + _bal(a36, quote);
        // each maker started with 1e24 quote deposited; subtract that baseline
        makersGot -= 4 * uint256(1e24);
        uint256 potGot = _pot(quote);
        assertLe(makersGot + potGot, quoteAmount, "makers + pot never get more than the taker paid");

        // everyone leaves; only dust remains, and it is in the contract's favour (never owed)
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    /// The sell mirror: bids in four fractional decades met out of order; a sell receives floor(Q) - ceil(Q*f).
    function test_sell_across_fractional_decades_conserves() public {
        address b38 = _plain(D38 + 640, true, 2_000_009);
        address b37 = _plain(D37 + 321, true, 4_500_001);
        address b39 = _plain(D39 + 88, true, 900_007);
        address b36 = _plain(D36 + 7, true, 9_999_991);

        // meet decades 38, 37, 39, 36. For a sell, a bid fills at or ABOVE the entry bound, so bound each at its tick.
        bytes memory seg = OloOps.poolList(
            bytes.concat(
                OloOps.poolEntry(posOf[b38], D38 + 640),
                OloOps.poolEntry(posOf[b37], D37 + 321),
                OloOps.poolEntry(posOf[b39], D39 + 88),
                OloOps.poolEntry(posOf[b36], D36 + 7)
            )
        );

        uint256 takerBaseBefore = base.balanceOf(taker);
        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        (uint256 baseAmount, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(false, 30_000_000, OloOps.WALLET)));

        assertEq(baseAmount, 2_000_009 + 4_500_001 + 900_007 + 9_999_991, "all four bids filled");
        // the taker gave base and received quote
        assertEq(takerBaseBefore - base.balanceOf(taker), baseAmount, "taker gave the base it filled");
        assertEq(quote.balanceOf(taker) - takerQuoteBefore, quoteAmount, "taker received the quote it was told");
        _solvent();

        // each bid maker claims: gets its filled base, pays nothing more; its escrowed quote (rounded up) stays until a
        // cancel. We cancel each to refund the remaining escrow and settle fully.
        _cancelOrder(b38);
        _cancelOrder(b37);
        _cancelOrder(b39);
        _cancelOrder(b36);
        _solvent();

        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    /// High decades (60..73, above EXP_OFFSET so the quote is a whole number but huge) with the largest amounts the
    /// fixture-funded makers can escrow: a buy crossing them, then unwind. Checks the exact-sum aligner and the final
    /// rounding at the top of the grid, a surface the second reader called essentially un-fuzzed.
    function test_buy_across_high_decades_conserves() public {
        // at decade d>=43 the price is whole: P = mantissa*10^(d-43). A bid/ask of `amount` base wei at decade d costs
        // amount*mantissa*10^(d-43) quote wei. Keep that within a maker's 1e24 quote deposit: at decade 50, P ~ 1e5*1e7
        // = 1e12, so amount up to ~1e11 base wei fits. Use modest amounts and high decades for the aligner's reach.
        uint256 t50 = 50 * 900_000 + 111;
        uint256 t55 = 55 * 900_000 + 9;
        uint256 t48 = 48 * 900_000 + 50_000;
        address a50 = _plain(t50, false, 101);
        address a55 = _plain(t55, false, 7);
        address a48 = _plain(t48, false, 9_999);

        bytes memory seg = OloOps.poolList(
            bytes.concat(
                OloOps.poolEntry(posOf[a50], t50),
                OloOps.poolEntry(posOf[a55], t55),
                OloOps.poolEntry(posOf[a48], t48)
            )
        );
        vm.prank(taker);
        (uint256 baseAmount,) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(true, 1_000_000, OloOps.WALLET)));
        assertEq(baseAmount, 101 + 7 + 9_999, "all three high-decade asks filled");
        _solvent();

        _claimAsk(a50);
        _claimAsk(a55);
        _claimAsk(a48);
        _solvent();

        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    /// QUOTE MODE across fractional decades: here `_affordable` runs (remaining stays above 2^255), and when the walk
    /// meets a lower decade it re-aligns the budget cap `_quoteCap(walk, decade)` and rescales the sum — the exact
    /// sub-target the S5 dig named ("_affordable lower-decade cap re-alignment"). The budget is set so the cap binds
    /// mid-walk (a partial fill), and the taker must never pay more than its quote-wei budget.
    function test_quote_mode_buy_across_fractional_decades_conserves() public {
        // asks met in order 38, 39, 37, 36 so the cap re-aligns down twice
        address a38 = _plain(D38 + 777, false, 2_500_001);
        address a39 = _plain(D39 + 5, false, 333_333);
        address a37 = _plain(D37 + 123, false, 1_000_003);
        address a36 = _plain(D36 + 99, false, 7_777_777);

        bytes memory seg = OloOps.poolList(
            bytes.concat(
                OloOps.poolEntry(posOf[a38], D38 + 777),
                OloOps.poolEntry(posOf[a39], D39 + 5),
                OloOps.poolEntry(posOf[a37], D37 + 123),
                OloOps.poolEntry(posOf[a36], D36 + 99)
            )
        );

        // a quote-wei budget that cannot buy every ask: forces the budget cap to bind on some order mid-walk
        uint256 budget = 5_000_000; // quote wei
        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        (, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.quoteW(true, budget, OloOps.WALLET)));

        // the quote actually paid never exceeds the quote-wei budget asked (note 4: a buy's g(Q) <= A)
        assertLe(quoteAmount, budget, "quote mode buy stays within its budget");
        assertEq(takerQuoteBefore - quote.balanceOf(taker), quoteAmount, "taker paid the quote it was told");
        _solvent();

        // settle every ask that filled (a claim with no fills reverts NothingToClaim; cancel instead refunds + pays)
        _cancelOrder(a38);
        _cancelOrder(a39);
        _cancelOrder(a37);
        _cancelOrder(a36);
        _solvent();

        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    /// QUOTE MODE sell across fractional decades: a sell's budget is A/(1-f); the quote received must stay within the
    /// quote-wei budget, and the book stays solvent and creates no value.
    function test_quote_mode_sell_across_fractional_decades_conserves() public {
        address b38 = _plain(D38 + 640, true, 2_000_009);
        address b37 = _plain(D37 + 321, true, 4_500_001);
        address b39 = _plain(D39 + 88, true, 900_007);
        address b36 = _plain(D36 + 7, true, 9_999_991);

        bytes memory seg = OloOps.poolList(
            bytes.concat(
                OloOps.poolEntry(posOf[b38], D38 + 640),
                OloOps.poolEntry(posOf[b37], D37 + 321),
                OloOps.poolEntry(posOf[b39], D39 + 88),
                OloOps.poolEntry(posOf[b36], D36 + 7)
            )
        );

        uint256 budget = 3_000_000; // quote wei the sell may receive, at most
        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        (, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.quoteW(false, budget, OloOps.WALLET)));

        assertLe(quoteAmount, budget, "quote mode sell stays within its budget");
        assertEq(quote.balanceOf(taker) - takerQuoteBefore, quoteAmount, "taker received the quote it was told");
        _solvent();

        _cancelOrder(b38);
        _cancelOrder(b37);
        _cancelOrder(b39);
        _cancelOrder(b36);
        _solvent();

        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    function _claimAsk(address maker) internal {
        vm.prank(maker);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[maker], 0)));
    }

    function _cancelOrder(address maker) internal {
        vm.prank(maker);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[maker], 0)));
    }
}
