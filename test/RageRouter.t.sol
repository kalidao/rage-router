// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Standard, RageRouter} from "../src/RageRouter.sol";

import {MockERC20} from "@solbase/test/utils/mocks/MockERC20.sol";
import {MockERC721Supply} from "@solbase/test/utils/mocks/MockERC721Supply.sol";
import {MockERC1155} from "@solbase/test/utils/mocks/MockERC1155.sol";

import "@std/Test.sol";

contract RageRouterTest is Test {
    using stdStorage for StdStorage;

    RageRouter router;

    MockERC20 mockGovERC20;
    MockERC721Supply mockGovERC721;
    MockERC1155 mockGovERC1155;

    MockERC20 mockDai;
    MockERC20 mockWeth;

    Standard private constant erc20std = Standard.ERC20;
    Standard private constant erc721std = Standard.ERC721;

    address private constant alice = 0x503408564C50b43208529faEf9bdf9794c015d52;
    address public immutable bob = 0x001d3F1ef827552Ae1114027BD3ECF1f086bA0F9;
    address private immutable treasury = address(this);

    /// -----------------------------------------------------------------------
    /// Setup
    /// -----------------------------------------------------------------------

    function setUp() public {
        router = new RageRouter();

        mockGovERC20 = new MockERC20("Gov", "GOV", 18);
        mockGovERC721 = new MockERC721Supply("Gov", "GOV");
        mockGovERC1155 = new MockERC1155();

        mockDai = new MockERC20("Dai", "DAI", 18);
        mockWeth = new MockERC20("wETH", "WETH", 18);

        // 50 mockGovERC20.
        mockGovERC20.mint(alice, 50 ether);
        // 50 mockGovERC20.
        mockGovERC20.mint(bob, 50 ether);

        // 1 mockGovERC721.
        mockGovERC721.mint(alice, 0);
        // 1 mockGovERC721.
        mockGovERC721.mint(bob, 1);

        // 1 mockGovERC1155.
        mockGovERC1155.mint(alice, 0, 1, "");
        // 1 mockGovERC1155.
        mockGovERC1155.mint(bob, 1, 1, "");

        // 1000 mockDai.
        mockDai.mint(address(this), 1000 ether);
        // 10 mockWeth.
        mockWeth.mint(address(this), 10 ether);

        // ERC20 approvals.
        mockGovERC20.approve(address(router), 100 ether);
        mockDai.approve(address(router), 1000 ether);
        mockWeth.approve(address(router), 10 ether);

        // Set redemption for governance ERC20.
        router.setRedemption(address(mockGovERC20), 0, 100);
        vm.warp(1641070800);
    }

    /// -----------------------------------------------------------------------
    /// Test Logic
    /// -----------------------------------------------------------------------

    function testDeploy() public payable {
        new RageRouter();
    }

    function testRedemptionERC20() public payable {
        // Check initial gov balances.
        assertTrue(mockGovERC20.balanceOf(alice) == 50 ether);
        assertTrue(mockGovERC20.totalSupply() == 100 ether);

        // Check initial unredeemed wETH.
        assertTrue(mockWeth.balanceOf(alice) == 0 ether);
        assertTrue(mockWeth.balanceOf(treasury) == 10 ether);
        
        // Set up wETH claim.
        address[] memory singleAsset = new address[](1);
        singleAsset[0] = address(mockWeth);

        // Mock alice to redeem gov for wETH.
        startHoax(alice, alice, type(uint256).max);
        router.redeem(treasury, singleAsset, address(mockGovERC20), erc20std, 0, 25 ether);
        vm.stopPrank();

        // Check resulting gov balances.
        assertTrue(mockGovERC20.balanceOf(alice) == 25 ether);
        assertTrue(mockGovERC20.totalSupply() == 75 ether);

        // Check resulting redeemed wETH.
        assertTrue(mockWeth.balanceOf(alice) == 2.5 ether);
        assertTrue(mockWeth.balanceOf(treasury) == 7.5 ether);
    }

    function testRedemptionERC721() public payable {
        // Check initial gov balances.
        assertTrue(mockGovERC721.ownerOf(0) == alice);
        assertTrue(mockGovERC721.balanceOf(alice) == 1);
        assertTrue(mockGovERC721.totalSupply() == 2);
        
        // Check initial unredeemed wETH.
        assertTrue(mockWeth.balanceOf(alice) == 0 ether);
        assertTrue(mockWeth.balanceOf(treasury) == 10 ether);
        
        // Set up wETH claim.
        address[] memory singleAsset = new address[](1);
        singleAsset[0] = address(mockWeth);
        
        // Mock alice to redeem gov for wETH.
        startHoax(alice, alice, type(uint256).max);
        router.redeem(treasury, singleAsset, address(mockGovERC721), erc721std, 0, 1);
        vm.stopPrank();
        /*
        // Check resulting gov balances.
        assertTrue(mockGovERC721.balanceOf(alice) == 0 ether);
        assertTrue(mockGovERC721.totalSupply() == 1 ether);
        
        // Check resulting redeemed wETH.
        assertTrue(mockWeth.balanceOf(alice) == 5 ether);
        assertTrue(mockWeth.balanceOf(treasury) == 5 ether);*/
    }
}