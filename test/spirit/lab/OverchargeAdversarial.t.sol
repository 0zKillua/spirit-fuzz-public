// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {IOloBookBase} from "../../../src/interfaces/IOloBookBase.sol";
import {MarketLib} from "../../../src/types/Market.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";
import {PriceGrid} from "../../../src/libraries/PriceGrid.sol";

/// Adversarial probes at taker pricing (prize-5dd56a49): a maker must never overcharge a taker by repricing worse
/// after the taker built its list, every fill is at the order's own tick bounded by the taker's entry, and quote-mode
/// never pays/receives past the stated amount.
contract OverchargeAdversarialTest is OloBase {
    using MarketLib for MarketWord;

    function setUp() public {
        _deploy();
    }

    function _feeUp(uint256 quote) internal view returns (uint256) {
        uint256 ppm = c.feePpm();
        return (quote * ppm + (PPM() - 1)) / PPM();
    }

    function PPM() internal pure returns (uint256) {
        return 1_000_000;
    }

    /// A maker that reprices its ask UP (worse for a buyer) after the taker listed it must not have the take fill at
    /// the new worse price: the entry tick bounds the price, so the repriced order is skipped and the taker pays
    /// nothing for it.
    function test_maker_repricing_up_cannot_overcharge_a_buyer() public {
        address mk = _plain(T, false, 10 * LOT); // ask at T
        uint32 pos = posOf[mk];
        // the maker moves the ask up to T+1000 (worse for a buyer bounded at T)
        vm.prank(mk);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, T + 1000, 10 * LOT, 0)));
        // the taker's list still names the position at the tick it saw (T)
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(taker);
        (uint256 baseAmt, uint256 quoteAmt) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, OloOps.WALLET)));
        assertEq(baseAmt, 0, "repriced-worse order is skipped, nothing filled");
        assertEq(quoteAmt, 0, "no quote paid");
        _solvent();
    }

    /// Every fill is at the order's OWN tick, never the taker's (more generous) entry tick. A buyer willing to pay up
    /// to T+50 against an ask resting at T pays the T price, not the T+50 price.
    function test_fill_is_at_the_orders_own_tick_not_the_entry_tick() public {
        address mk = _plain(T, false, 10 * LOT); // ask at T
        uint32 pos = posOf[mk];
        // the taker's entry names a generous bound T+50 (willing to pay more), but the order rests at T
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T + 50));
        vm.prank(taker);
        (uint256 baseAmt, uint256 quoteAmt) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, OloOps.WALLET)));
        assertEq(baseAmt, 3 * LOT, "filled 3 lots");
        uint256 quoteAtOwn = _qu(3 * LOT, T);
        assertEq(quoteAmt, quoteAtOwn + _feeUp(quoteAtOwn), "paid the order's own-tick price + fee, not the entry's");
        // and strictly less than what the entry tick T+50 would have cost: no overcharge
        assertLt(quoteAmt, _qd(3 * LOT, T + 50), "own-tick price is below the generous entry-tick price");
        _solvent();
        _everyoneLeaves();
    }

    /// A quote-mode buy never pays more than the stated amount (quote + fee <= amount).
    function test_quote_mode_buy_never_exceeds_the_amount() public {
        address mk = _plain(T, false, 1000 * LOT); // deep ask at T
        uint32 pos = posOf[mk];
        uint256 amount = 1_234_567; // quote wei budget
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(taker);
        (uint256 baseAmt, uint256 quoteAmt) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.quoteW(true, amount, OloOps.WALLET)));
        assertGt(baseAmt, 0, "something filled");
        assertLe(quoteAmt, amount, "quote + fee never exceeds the quote-mode budget");
        _solvent();
        _everyoneLeaves();
    }

    /// A quote-mode sell never receives more than the stated amount (quote - fee <= amount), and leftover is the
    /// taker's. Here a seller hits a deep bid.
    function test_quote_mode_sell_never_exceeds_the_amount() public {
        address mk = _plain(T, true, 1000 * LOT); // deep bid at T (escrows quote)
        uint32 pos = posOf[mk];
        uint256 amount = 2_345_678; // the most quote the seller will receive
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(taker);
        (uint256 baseAmt, uint256 quoteAmt) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.quoteW(false, amount, OloOps.WALLET)));
        assertGt(baseAmt, 0, "something filled");
        assertLe(quoteAmt, amount, "quote - fee never exceeds the quote-mode budget");
        _solvent();
        _everyoneLeaves();
    }
}
