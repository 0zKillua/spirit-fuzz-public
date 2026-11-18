// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";
import {IOloFlashCallback} from "../../../src/interfaces/IOloFlashCallback.sol";

/// A flash caller that, inside the callback, runs a program: places a bid escrowing the credited quote, then as a
/// seller fills its own bid in WALLET mode to pull a third party's real quote out of the contract, and (optionally)
/// deposits it back to satisfy the final debit.
contract FlashThief is IOloFlashCallback {
    address book;
    bytes[] program;

    function arm(address book_, bytes[] memory program_) external {
        book = book_;
        delete program;
        for (uint256 i; i < program_.length; ++i) program.push(program_[i]);
    }

    function oloFlashCallback(address, uint256, bytes calldata) external {
        require(msg.sender == book, "caller");
        for (uint256 i; i < program.length; ++i) {
            (bool ok, bytes memory ret) = book.call(program[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

contract AdversarialTest is OloBase {
    function setUp() public {
        _deploy();
    }

    /// A take list that names the same pool position twice must not fill more than the order's open units.
    function test_double_listed_position_cannot_overfill() public {
        address mk = _plain(T, false, 5 * LOT); // ask of 5 LOT at T
        uint32 pos = posOf[mk];
        // list the same position twice, each bounded at T
        bytes memory entries = bytes.concat(OloOps.poolEntry(pos, T), OloOps.poolEntry(pos, T));
        bytes memory list = OloOps.poolList(entries);
        vm.prank(taker);
        (uint256 baseAmt,) = book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 100 * LOT, OloOps.WALLET)));
        assertEq(baseAmt, 5 * LOT, "fills exactly the open units, not twice");
        _solvent();
        _everyoneLeaves();
    }

    /// An attacker flashes quote, escrows it in its own bid, then sells into that bid in WALLET mode to pull a victim's
    /// real quote out of the contract, and never deposits it back: the flash's final debit must force the whole call to
    /// revert, so the victim's deposit is untouched.
    function test_flash_cannot_steal_a_depositors_quote() public {
        // a victim deposits 100 LOT of quote into the book (real quote now sits in the contract)
        vm.prank(taker);
        book.deposit(address(quote), 100 * LOT);
        uint256 victimBefore = _bal(taker, quote);
        assertEq(victimBefore, 100 * LOT, "victim funded");

        FlashThief thief = new FlashThief();
        base.mint(address(thief), 1e24);
        quote.mint(address(thief), 1e24); // some wallet quote, but NOT enough reason to self-repay in the attack
        vm.startPrank(address(thief));
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        vm.stopPrank();

        uint32 bidPos = 2000;
        uint256 x = 3 * LOT; // base the bid buys
        uint256 escrow = _qu(x, T); // quote the bid escrows (=3e6 at price 1.0)

        // program run inside the callback: place a bid escrowing the credited quote (account mode), then sell base
        // into it in WALLET mode, pulling real quote to the thief's wallet
        bytes[] memory program = new bytes[](2);
        program[0] = abi.encodeCall(book.place, (OloOps.key(c), OloOps.placeW(true, T, x, bidPos, 0)));
        bytes memory list = OloOps.poolList(OloOps.poolEntry(bidPos, T));
        program[1] =
            abi.encodeCall(book.take, (OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(false, x, OloOps.WALLET))));
        thief.arm(address(book), program);

        // flashing exactly the escrow: the credit is spent on the bid, so the final debit cannot be satisfied
        vm.prank(address(thief));
        vm.expectRevert(); // InsufficientBalance on the repayment debit
        book.flash(address(quote), escrow, "");

        // the victim's deposit is intact and the contract is solvent
        assertEq(_bal(taker, quote), victimBefore, "victim quote untouched");
        _solvent();
    }

    /// Control: the same self-fill program, but the attacker deposits the escrow back so the repayment debit succeeds.
    /// The flash then goes through — proving the extraction path is real and well-formed — yet the victim is still
    /// untouched and the contract stays solvent (the attacker only paid the taker fee).
    function test_flash_self_fill_with_repayment_is_no_theft() public {
        vm.prank(taker);
        book.deposit(address(quote), 100 * LOT);
        uint256 victimBefore = _bal(taker, quote);

        FlashThief thief = new FlashThief();
        base.mint(address(thief), 1e24);
        quote.mint(address(thief), 1e24);
        vm.startPrank(address(thief));
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        vm.stopPrank();

        uint32 bidPos = 2001;
        uint256 x = 3 * LOT;
        uint256 escrow = _qu(x, T);

        bytes[] memory program = new bytes[](3);
        program[0] = abi.encodeCall(book.place, (OloOps.key(c), OloOps.placeW(true, T, x, bidPos, 0)));
        bytes memory list = OloOps.poolList(OloOps.poolEntry(bidPos, T));
        program[1] =
            abi.encodeCall(book.take, (OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(false, x, OloOps.WALLET))));
        // deposit the escrow back from the wallet to satisfy the repayment debit
        program[2] = abi.encodeCall(book.deposit, (address(quote), escrow));
        thief.arm(address(book), program);

        vm.prank(address(thief));
        book.flash(address(quote), escrow, ""); // succeeds now

        assertEq(_bal(taker, quote), victimBefore, "victim quote still untouched after a successful flash");
        _solvent();
    }
}
