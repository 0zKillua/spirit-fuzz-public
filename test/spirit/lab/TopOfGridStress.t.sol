// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {PriceGrid} from "../../../src/libraries/PriceGrid.sol";

/// Lead-authored (S7), prize-b201485d, thread-e406bd3d.
///
/// THE HINGE: OloBookTakes.sol:470, `quote = sum * OloMath.pow10(low - 43)`, UNCHECKED. Every prior session flagged this
/// as the one concrete value-creation/overflow concern reasoned "unreachable" but NEVER executed at the extreme. These
/// tests push to the GRID'S TRUE TOP: tick = PriceGrid.MAX_TICK (decade 73, P = 999_999e30 ~ 1e36 quote wei per base
/// wei) with a base fill near the 2^112 input cap, i.e. the LARGEST real quote any reachable take can produce (~5e69 ~
/// 2^232) — the closest the contract can get to the 2^256 wrap. If :470 wrapped, the taker would pay a tiny value for
/// the makers' base.
contract TopOfGridStressTest is OloBase {
    uint256 constant MAX_TICK = PriceGrid.MAX_TICK; // 66_599_999: decade 73, mantissa 999_999
    uint256 constant D60 = 60 * 900_000; // decade 60 bottom
    uint8 constant SETTLE_WALLET = 0x02; // SettleFlags.WALLET (distinct from the take-mode WALLET=0x01)

    function setUp() public {
        _deploy(); // fee 50 ppm, global maker share 10_000 (maker takes the whole fee)
    }

    /// STAGE A — the take alone at the top of the grid. The quote reported must be the exact whole top-of-grid value
    /// (~5e69), dwarfing the base, and the taker must have paid exactly that. No wrap, no revert, book solvent.
    function test_A_take_at_top_tick_no_wrap() public {
        uint256 amount = 5e33; // < 2^112 (5.19e33)
        address a = _bigAsk(address(0x7300), MAX_TICK, amount);
        quote.mint(taker, 1e71);

        bytes memory seg = OloOps.poolList(OloOps.poolEntry(posOf[a], MAX_TICK));

        uint256 takerQuoteBefore = quote.balanceOf(taker);
        uint256 takerBaseBefore = base.balanceOf(taker);
        vm.prank(taker);
        (uint256 baseAmount, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(true, amount, OloOps.WALLET)));

        assertEq(baseAmount, amount, "the whole ask filled");
        assertEq(base.balanceOf(taker) - takerBaseBefore, baseAmount, "taker received the base");
        assertEq(takerQuoteBefore - quote.balanceOf(taker), quoteAmount, "taker paid exactly what take reported");
        // the exact whole quote at decade 73: base * mantissa * 10^30, plus fee ceil'd — NOT a tiny wrapped value
        uint256 expectedQuote = PriceGrid.quoteUp(baseAmount, MAX_TICK);
        assertEq(quoteAmount, expectedQuote + _feeUp(expectedQuote), "quote+fee is the exact top-of-grid value");
        assertGt(quoteAmount, baseAmount, "quote dwarfs base: no wrap");
        _solvent();
    }

    /// STAGE B — conservation: the maker claims to its WALLET (proceeds ~5e69 exceed a 2^128 account), everyone leaves,
    /// only dust in the contract's favour.
    function test_B_top_tick_conserves() public {
        uint256 amount = 5e33;
        address a = _bigAsk(address(0x7300), MAX_TICK, amount);
        quote.mint(taker, 1e71);

        bytes memory seg = OloOps.poolList(OloOps.poolEntry(posOf[a], MAX_TICK));
        vm.prank(taker);
        (, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(true, amount, OloOps.WALLET)));
        _solvent();

        uint256 makerQuoteWalletBefore = quote.balanceOf(a);
        vm.prank(a);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a], SETTLE_WALLET)));
        uint256 makerGot = quote.balanceOf(a) - makerQuoteWalletBefore;
        _solvent();

        uint256 potGot = _pot(quote);
        assertLe(makerGot + potGot, quoteAmount, "makers + pot <= taker paid (no value created)");

        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    /// STAGE C — two asks in different high decades (73 then 60), met out of order so `_accrue` runs its scaling branch
    /// at a high `low`. Multi-order stress on :470 and the SUM_LIMIT guard.
    function test_C_two_high_decades_conserve() public {
        uint256 amt73 = 3e33;
        uint256 amt60 = 2e33;
        address a73 = _bigAsk(address(0x7301), MAX_TICK, amt73);
        address a60 = _bigAsk(address(0x6001), D60 + 123, amt60);
        quote.mint(taker, 1e71);

        bytes memory seg = OloOps.poolList(
            bytes.concat(OloOps.poolEntry(posOf[a73], MAX_TICK), OloOps.poolEntry(posOf[a60], D60 + 123))
        );
        uint256 takerQuoteBefore = quote.balanceOf(taker);
        vm.prank(taker);
        (uint256 baseAmount, uint256 quoteAmount) =
            book.take(OloOps.key(c), seg, OloOps.tagW(c, OloOps.takeW(true, amt73 + amt60, OloOps.WALLET)));
        assertGt(baseAmount, 0, "filled");
        assertEq(takerQuoteBefore - quote.balanceOf(taker), quoteAmount, "taker paid what take reported");
        _solvent();

        uint256 mq73 = quote.balanceOf(a73);
        uint256 mq60 = quote.balanceOf(a60);
        vm.prank(a73);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a73], SETTLE_WALLET)));
        vm.prank(a60);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[a60], SETTLE_WALLET)));
        uint256 makersGot = (quote.balanceOf(a73) - mq73) + (quote.balanceOf(a60) - mq60);
        _solvent();

        assertLe(makersGot + _pot(quote), quoteAmount, "makers + pot <= taker paid");
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "dust base only");
        assertLe(quoteLeft, 100, "dust quote only");
    }

    function _feeUp(uint256 q) internal pure returns (uint256) {
        uint256 v = q * 50;
        uint256 out = v / 1_000_000;
        return v % 1_000_000 == 0 ? out : out + 1;
    }

    function _bigAsk(address who, uint256 tick, uint256 amount) internal returns (address a) {
        a = _makerAt(who); // deposits 1e24 of each; mints 1e30 of each; approves max
        base.mint(a, amount + 1);
        vm.startPrank(a);
        book.deposit(address(base), amount); // base account now 1e24 + amount (< 2^128)
        uint32 pos = _pos();
        posOf[a] = pos;
        tickOf[a] = tick;
        book.place(OloOps.key(c), OloOps.placeW(false, tick, amount, pos, 0));
        vm.stopPrank();
    }
}
