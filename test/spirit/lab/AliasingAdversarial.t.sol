// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {IOloBookBase} from "../../../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";
import {MarketLib, C_TAG_FIELD} from "../../../src/types/Market.sol";

/// The withTag / C key+tag aliasing crack (prize-96b11e9b ownership + prize-b201485d drain), which the prior lead
/// flagged as the one remaining crack and a cold dig (dig-d99bd515) was dispatched at but never produced a usable
/// report. The caller supplies the market word C (or K.withTag(params)); every order/batch/account slot is hashed from
/// it. The claim is that no crafted C can (a) reach another owner's order/escrow, nor (b) redirect a settle's proceeds
/// to a token account the caller does not own, nor (c) re-settle the caller's own order at a fee/share version other
/// than the one it rests in. This file fuzzes the structural invariant and runs the end-to-end attacks.
contract AliasingAdversarialTest is OloBase {
    using MarketLib for MarketWord;

    address attacker = address(0xA77ACC);

    function setUp() public {
        _deploy();
        base.mint(attacker, 1e30);
        quote.mint(attacker, 1e30);
        vm.startPrank(attacker);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// The core structural invariant behind the whole ownership/solvency argument: withTag OR-s the carried tag into
    /// C's tag field (bits 174-223) and NOTHING ELSE. So for any key K a caller supplies and any carrier it crafts, the
    /// base id, quote id, market id, spacing, minQuote and proprietary bit of the resulting C are exactly K's. Since
    /// _acctKeys(C) is derived only from the base/quote id fields, no crafted carrier can ever move a settle's proceeds
    /// to a different token account; and since the market id is fixed, a crafted tag stays within the same market.
    function testFuzz_withTag_only_touches_the_tag_bits(uint256 kNoise, uint256 carrier) public view {
        // start from the real market key and let the fuzzer smear arbitrary bits into K too (the caller controls K)
        MarketWord k = MarketWord.wrap(MarketWord.unwrap(OloOps.key(c)) | kNoise);
        MarketWord cc = k.withTag(carrier);
        // every bit outside the tag field is unchanged by withTag
        assertEq(
            (MarketWord.unwrap(cc) ^ MarketWord.unwrap(k)) & ~C_TAG_FIELD, 0, "withTag changed a non-tag bit"
        );
        // and in particular the token identity and the market id are preserved
        assertEq(cc.baseId(), k.baseId(), "baseId moved");
        assertEq(cc.quoteId(), k.quoteId(), "quoteId moved");
        assertEq(cc.marketId(), k.marketId(), "marketId moved");
        assertEq(cc.spacing(), k.spacing(), "spacing moved");
        assertEq(cc.minQuote(), k.minQuote(), "minQuote moved");
        assertEq(cc.isProprietary(), k.isProprietary(), "proprietary bit moved");
    }

    /// A crafted C whose token-id (key) bits differ from the victim's market hashes every order op to a DIFFERENT slot,
    /// which is empty: NoOrder. The victim's escrow never moves, and the victim can still cancel in full.
    function test_crafted_key_bits_reach_no_order() public {
        address victim = _plain(T, false, 10 * LOT); // victim rests an ask, 10 LOT base escrowed
        uint32 pos = posOf[victim];
        uint256 vBaseBefore = _bal(victim, base);

        // flip one base-id bit of the key: a market nobody listed, a different slot
        MarketWord wrongKey = MarketWord.wrap(MarketWord.unwrap(OloOps.key(c)) ^ 1);

        // cancel / claim at the wrong key land on an empty slot -> NoOrder (not NotOrderOwner: the slot is not even the
        // victim's). modify first checks the crafted C is a current market (_checkCurrent) and the wrong key is no
        // market -> UnknownMarket. Either way nothing of the victim's is reached.
        vm.startPrank(attacker);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.cancel(wrongKey, OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.claim(wrongKey, OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.expectRevert(IOloBookBase.UnknownMarket.selector);
        book.modify(wrongKey, OloOps.tagW(c, OloOps.modifyW(pos, T, 1 * LOT, 0)));
        vm.stopPrank();

        // and the real key reaches the order but the owner check stops the attacker
        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));

        assertEq(_bal(victim, base), vBaseBefore, "victim escrow untouched");
        _solvent();
        // the victim still cancels its own order in full
        vm.prank(victim);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        _solvent();
        _everyoneLeaves();
    }

    /// An adversarial MAKER cannot re-settle its own filled order at a newer, more generous maker-share version to take
    /// a bigger cut of the fee from the protocol pot: the share/fee/version all live in the tag, which hashes into the
    /// order's slot, so the order is only ever found (and settled) at the exact version it rests in. Claiming with a
    /// different version's tag finds an empty slot (NoOrder). This is the MarketFrozen guarantee seen from the maker.
    function test_maker_cannot_resettle_at_a_newer_share() public {
        // the version the order rests in, captured before any change
        MarketWord cOrder = c;

        // a maker rests an ask and a taker fills part of it, all in cOrder's version
        address maker = _maker();
        vm.prank(maker);
        book.place(OloOps.key(cOrder), OloOps.placeW(false, T, 10 * LOT, 7777, 0));
        bytes memory list = OloOps.poolList(OloOps.poolEntry(7777, T));
        vm.prank(taker);
        book.take(OloOps.key(cOrder), list, OloOps.tagW(cOrder, OloOps.takeW(true, 4 * LOT, OloOps.WALLET)));

        // the owner moves the market's maker share to a new version (a value guaranteed different from the current one)
        _setMarketShare(cOrder.makerBps() == 5_000 ? 6_000 : 5_000);
        MarketWord cNew = c; // a different version (different tag -> different slot)
        assertTrue(MarketWord.unwrap(cNew) != MarketWord.unwrap(cOrder), "share change made no new version");

        uint256 potBefore = _pot(quote);

        // the maker tries to claim its fills under the NEW version's tag: that slot is empty -> NoOrder
        vm.prank(maker);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        book.claim(OloOps.key(cNew), OloOps.tagW(cNew, OloOps.posW(7777, 0)));
        assertEq(_pot(quote), potBefore, "pot moved on the failed claim");

        // the only claim that works is at the order's own version; the book stays solvent and everyone leaves whole
        vm.prank(maker);
        book.claim(OloOps.key(cOrder), OloOps.tagW(cOrder, OloOps.posW(7777, 0)));
        _solvent();

        vm.prank(maker);
        book.cancel(OloOps.key(cOrder), OloOps.tagW(cOrder, OloOps.posW(7777, 0)));
        _solvent();
        _everyoneLeaves();
    }

    /// A multicall cannot be used to cancel a victim's order: the CANCEL op runs _cancelOp on the stream's market, which
    /// still checks the order's stored owner, so the whole multicall reverts NotOrderOwner and no flow is committed.
    function test_multicall_cannot_cancel_a_victims_order() public {
        address victim = _plain(T, false, 10 * LOT);
        uint32 pos = posOf[victim];
        uint256 vBaseBefore = _bal(victim, base);

        bytes memory data = _mc(OloOps.cancel(0, pos)); // header(c) + a CANCEL op naming the victim's position
        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.multicall(0, data);

        assertEq(_bal(victim, base), vBaseBefore, "victim escrow untouched by the multicall");
        _solvent();
        _everyoneLeaves();
    }

    /// Control: the victim itself cancels through the very same multicall shape and is refunded in full — proving the
    /// revert above is the owner guard, not a malformed call.
    function test_multicall_owner_can_cancel_control() public {
        address victim = _plain(T, false, 10 * LOT);
        uint32 pos = posOf[victim];
        uint256 vBaseBefore = _bal(victim, base);

        bytes memory data = _mc(OloOps.cancel(0, pos));
        vm.prank(victim);
        book.multicall(0, data); // AUTO off, WALLET off: the refund lands in the account
        assertEq(_bal(victim, base) - vBaseBefore, 10 * LOT, "victim refunded its escrow in full");
        _solvent();
        _everyoneLeaves();
    }
}
