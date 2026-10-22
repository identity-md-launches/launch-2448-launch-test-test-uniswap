// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TestToken} from "../src/TestToken.sol";
import {PoolActor} from "./helpers/PoolActor.sol";

contract TestTokenTest is Test {
    TestToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address spender = makeAddr("spender");

    function setUp() public {
        token = new TestToken();
    }

    function test_metadataAndFactoryMint() public {
        PoolActor factory = new PoolActor(IPoolManager(makeAddr("unused manager")));
        TestToken fromFactory = factory.deployToken();
        assertEq(fromFactory.name(), "test");
        assertEq(fromFactory.symbol(), "TEST");
        assertEq(fromFactory.decimals(), 18);
        assertEq(fromFactory.totalSupply(), 1_000_000_000 ether);
        assertEq(fromFactory.balanceOf(address(factory)), fromFactory.totalSupply());
        assertEq(fromFactory.balanceOf(address(this)), 0);
    }

    function test_factoryAllocationAndContractTransfers() public {
        address pool = makeAddr("pool");
        PoolActor distributor = new PoolActor(IPoolManager(makeAddr("unused manager")));
        address recipient = 0x5Bff2a2FEcD1d6152676813b21346238733bEAB1;
        uint256 supply = token.totalSupply();
        uint256 poolShare = FullMath.mulDiv(supply, 1000, 10_000);
        uint256 swarmShare = FullMath.mulDiv(supply, 1000, 10_000);
        assertTrue(token.transfer(pool, poolShare));
        assertTrue(token.transfer(address(distributor), swarmShare));
        assertTrue(token.transfer(recipient, supply - poolShare - swarmShare));
        vm.prank(address(distributor));
        assertTrue(token.transfer(alice, swarmShare));
        vm.prank(pool);
        assertTrue(token.transfer(bob, poolShare));
        assertEq(token.balanceOf(alice), 100_000_000 ether);
        assertEq(token.balanceOf(bob), 100_000_000 ether);
        assertEq(token.balanceOf(recipient), 800_000_000 ether);
        assertEq(token.totalSupply(), supply);
    }

    function testFuzz_plainTransfersAndAllowances(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        uint256 supply = token.totalSupply();
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(address(this)), supply - amount);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), supply);
    }

    function test_insufficientBalanceAndAllowanceRevert() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), bob, 1);
    }

    function test_noAdminMintBurnOrUpgradeSelectors() public {
        string[11] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "pause()",
            "unpause()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(selectors[i], alice, 1));
            assertFalse(success, selectors[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(alice), 0);
    }
}
