// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {IOloBookBase} from "../../../src/interfaces/IOloBookBase.sol";
import {IOloMarketPolicy} from "../../../src/interfaces/IOloMarketPolicy.sol";
import {MarketLib} from "../../../src/types/Market.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";

/// A policy by role that can also be flipped to "refuse everyone" (revert on every ask), to prove leaving-only ops
/// never call it.
contract FlipPolicy is IOloMarketPolicy {
    mapping(address => bool) public maker;
    mapping(address => bool) public taker;
    bool public refuseAll;

    function set(address who, bool canMake, bool canTake) external {
        maker[who] = canMake;
        taker[who] = canTake;
    }

    function setRefuseAll(bool v) external {
        refuseAll = v;
    }

    function admitted(uint32, address who, bool isMaker) external view returns (bool) {
        require(!refuseAll, "policy down"); // a reverting policy refuses (NotAdmitted) and must never gate a leave
        return isMaker ? maker[who] : taker[who];
    }
}

/// Adversarial probes at the proprietary-market policy (prize-eda0cc41): a non-admitted maker/taker must be refused,
/// and a leaving-only op (cancel/claim/deposit/withdraw) must NEVER ask the policy, so a hostile or broken policy can
/// never trap a maker's escrow or a depositor's balance.
contract ProprietaryAdversarialTest is OloBase {
    using MarketLib for MarketWord;

    FlipPolicy policy;
    address lister = address(0x1157E5);
    uint32 pm;
    MarketWord pc;
    MarketWord pk;

    function setUp() public {
        _deploy();
        policy = new FlipPolicy();
        book.setProprietaryListingAllowed(lister, true);
        vm.prank(lister);
        pm = book.listMarketQuoteProprietary(address(base), address(quote), 50, 6, 1, 0, address(policy));
        pc = book.configOf(pm);
        pk = OloOps.key(pc);
    }

    function _fundedMaker(bool canMake, bool canTake) internal returns (address a) {
        a = _maker(); // deposits 1e24 of each
        policy.set(a, canMake, canTake);
    }

    /// A maker the policy does not admit cannot rest an order (NotAdmitted).
    function test_non_admitted_maker_cannot_place() public {
        address a = _fundedMaker(false, false);
        uint32 pos = _pos();
        vm.prank(a);
        vm.expectRevert(IOloBookBase.NotAdmitted.selector);
        book.place(pk, OloOps.placeW(false, T, 10 * LOT, pos, 0));
    }

    /// A taker the policy does not admit cannot take (NotAdmitted).
    function test_non_admitted_taker_cannot_take() public {
        address mk = _fundedMaker(true, false);
        uint32 pos = _pos();
        vm.prank(mk);
        book.place(pk, OloOps.placeW(false, T, 10 * LOT, pos, 0)); // admitted maker rests an ask

        address badTaker = _fundedMaker(false, false);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(badTaker);
        vm.expectRevert(IOloBookBase.NotAdmitted.selector);
        book.take(pk, list, OloOps.tagW(pc, OloOps.takeW(true, 3 * LOT, 0)));
    }

    /// The anti-griefing core: an admitted maker rests an order, then the policy is turned hostile (reverts on every
    /// ask). The maker can STILL cancel and recover its escrow in full, because a cancel never asks the policy.
    function test_hostile_policy_cannot_trap_a_makers_escrow() public {
        address mk = _fundedMaker(true, false);
        uint32 pos = _pos();
        vm.prank(mk);
        book.place(pk, OloOps.placeW(false, T, 10 * LOT, pos, 0)); // escrows 10 LOT base
        uint256 baseBefore = _bal(mk, base);

        // the policy goes hostile: any ask now reverts
        policy.setRefuseAll(true);
        // a fresh place IS gated and fails (control: the policy really is hostile now)
        uint32 pos2 = _pos();
        vm.prank(mk);
        vm.expectRevert(IOloBookBase.NotAdmitted.selector);
        book.place(pk, OloOps.placeW(false, T, 1 * LOT, pos2, 0));

        // but the cancel goes through and refunds the escrow: it never asked the policy
        vm.prank(mk);
        book.cancel(pk, OloOps.tagW(pc, OloOps.posW(pos, 0)));
        assertEq(_bal(mk, base) - baseBefore, 10 * LOT, "escrow fully refunded despite the hostile policy");
        _solvent();
    }

    /// Deposits and withdrawals never ask the policy: a depositor can move funds in and out of the book even when the
    /// market's policy refuses everyone. (Accounts are per-token and not market-scoped, but this pins that the
    /// proprietary listing does not gate the ledger.)
    function test_deposit_and_withdraw_never_ask_the_policy() public {
        policy.setRefuseAll(true);
        address user = address(0xD0E);
        base.mint(user, 1e24);
        vm.startPrank(user);
        base.approve(address(book), type(uint256).max);
        book.deposit(address(base), 5 * LOT); // no policy ask
        book.withdraw(address(base), 5 * LOT); // no policy ask
        vm.stopPrank();
        assertEq(base.balanceOf(user), 1e24, "funds moved freely; policy never consulted");
        _solvent();
    }

    /// An admitted maker's resting order keeps filling after the policy stops admitting the maker, until the maker
    /// cancels it: a revoked maker's liquidity is honoured for takers the policy still admits.
    function test_revoked_makers_order_still_fills() public {
        address mk = _fundedMaker(true, false);
        uint32 pos = _pos();
        vm.prank(mk);
        book.place(pk, OloOps.placeW(false, T, 10 * LOT, pos, 0));
        // revoke the maker; admit a taker
        policy.set(mk, false, false);
        address tk = _fundedMaker(false, true);
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(tk);
        (uint256 baseAmt,) = book.take(pk, list, OloOps.tagW(pc, OloOps.takeW(true, 3 * LOT, 0)));
        assertEq(baseAmt, 3 * LOT, "the revoked maker's order still fills for an admitted taker");
        _solvent();
    }
}
