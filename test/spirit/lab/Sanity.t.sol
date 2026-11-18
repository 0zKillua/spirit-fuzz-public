// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";

/// Sanity: the lab harness deploys and runs an honest place+take, contract stays solvent.
contract SanityTest is OloBase {
    function setUp() public {
        _deploy();
    }

    function test_sanity_place_and_take() public {
        // a maker rests an ask of 10 LOT at T; the taker buys 3 LOT
        address mk = _plain(T, false, 10 * LOT);
        uint32 pos = posOf[mk];
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(taker);
        (uint256 baseAmt, uint256 quoteAmt) =
            book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, OloOps.WALLET)));
        assertEq(baseAmt, 3 * LOT, "filled 3 lots");
        // quote ~ 3 LOT at price 1.0 = 3e6, fee 50ppm rounded up
        assertGt(quoteAmt, 3 * LOT, "pays quote + fee");
        _solvent();
        // maker claims, then everyone leaves without revert
        vm.prank(mk);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        _everyoneLeaves();
    }
}
