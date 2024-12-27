// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoin.sol";

contract StableCoinTest is Test {
    StableCoin public stableCoin;
    address public owner;
    address public user;
    address public spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");
        spender = makeAddr("spender");
        stableCoin = new StableCoin(owner);
    }

    function testInitialState() public {
        assertEq(stableCoin.name(), "StableCoin", "Wrong name");
        assertEq(stableCoin.symbol(), "SC", "Wrong symbol");
        assertEq(stableCoin.decimals(), 18, "Wrong decimals");
        assertEq(stableCoin.totalSupply(), 0, "Initial supply should be 0");
        assertEq(stableCoin.owner(), owner, "Wrong owner");
    }

    function testMint() public {
        uint256 amount = 100e18;
        
        // Test minting as owner
        stableCoin.mint(user, amount);
        assertEq(stableCoin.balanceOf(user), amount, "Wrong balance after mint");
        assertEq(stableCoin.totalSupply(), amount, "Wrong total supply after mint");

        // Test minting to zero address should revert
        bytes memory expectedError = abi.encodeWithSignature(
            "ERC20InvalidReceiver(address)", 
            address(0)
        );
        vm.expectRevert(expectedError);
        stableCoin.mint(address(0), amount);

        // Test minting as non-owner should revert
        vm.startPrank(user);
        bytes memory expectedOwnableError = abi.encodeWithSignature(
            "OwnableUnauthorizedAccount(address)", 
            user
        );
        vm.expectRevert(expectedOwnableError);
        stableCoin.mint(user, amount);
        vm.stopPrank();
    }

    function testBurn() public {
        uint256 amount = 100e18;
        
        // Setup: mint tokens to user
        stableCoin.mint(user, amount);
        
        // Test burning
        vm.startPrank(user);
        stableCoin.burn(amount / 2);
        assertEq(stableCoin.balanceOf(user), amount / 2, "Wrong balance after burn");
        assertEq(stableCoin.totalSupply(), amount / 2, "Wrong total supply after burn");

        // Test burning more than balance should revert
        bytes memory expectedError = abi.encodeWithSignature(
            "ERC20InsufficientBalance(address,uint256,uint256)", 
            user, 
            amount / 2, 
            amount
        );
        vm.expectRevert(expectedError);
        stableCoin.burn(amount);
        vm.stopPrank();
    }

    function testBurnFrom() public {
        uint256 amount = 100e18;
        
        // Setup: mint tokens to user
        stableCoin.mint(user, amount);
        
        // Test burnFrom without approval should revert
        vm.startPrank(spender);
        bytes memory expectedError = abi.encodeWithSignature(
            "ERC20InsufficientAllowance(address,uint256,uint256)", 
            spender, 
            0, 
            amount
        );
        vm.expectRevert(expectedError);
        stableCoin.burnFrom(user, amount);
        vm.stopPrank();

        // Test burnFrom with approval
        vm.prank(user);
        stableCoin.approve(spender, amount);
        
        vm.startPrank(spender);
        stableCoin.burnFrom(user, amount / 2);
        assertEq(stableCoin.balanceOf(user), amount / 2, "Wrong balance after burnFrom");
        assertEq(stableCoin.totalSupply(), amount / 2, "Wrong total supply after burnFrom");
        assertEq(stableCoin.allowance(user, spender), amount / 2, "Wrong allowance after burnFrom");
        vm.stopPrank();
    }

    function testTransfer() public {
        uint256 amount = 100e18;
        
        // Setup: mint tokens to user
        stableCoin.mint(user, amount);
        
        // Test transfer
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user, spender, amount / 2);
        stableCoin.transfer(spender, amount / 2);
        assertEq(stableCoin.balanceOf(user), amount / 2, "Wrong sender balance after transfer");
        assertEq(stableCoin.balanceOf(spender), amount / 2, "Wrong recipient balance after transfer");

        // Test transfer more than balance should revert
        bytes memory expectedError = abi.encodeWithSignature(
            "ERC20InsufficientBalance(address,uint256,uint256)", 
            user, 
            amount / 2, 
            amount
        );
        vm.expectRevert(expectedError);
        stableCoin.transfer(spender, amount);
        vm.stopPrank();
    }

    function testTransferFrom() public {
        uint256 amount = 100e18;
        
        // Setup: mint tokens to user
        stableCoin.mint(user, amount);
        
        // Test transferFrom without approval should revert
        vm.startPrank(spender);
        bytes memory expectedError = abi.encodeWithSignature(
            "ERC20InsufficientAllowance(address,uint256,uint256)", 
            spender, 
            0, 
            amount
        );
        vm.expectRevert(expectedError);
        stableCoin.transferFrom(user, spender, amount);
        vm.stopPrank();

        // Test transferFrom with approval
        vm.prank(user);
        stableCoin.approve(spender, amount);
        
        vm.startPrank(spender);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user, spender, amount / 2);
        stableCoin.transferFrom(user, spender, amount / 2);
        assertEq(stableCoin.balanceOf(user), amount / 2, "Wrong sender balance after transferFrom");
        assertEq(stableCoin.balanceOf(spender), amount / 2, "Wrong recipient balance after transferFrom");
        assertEq(stableCoin.allowance(user, spender), amount / 2, "Wrong allowance after transferFrom");
        vm.stopPrank();
    }

    function testApprove() public {
        uint256 amount = 100e18;
        
        // Test approve
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true);
        emit Approval(user, spender, amount);
        stableCoin.approve(spender, amount);
        assertEq(stableCoin.allowance(user, spender), amount, "Wrong allowance after approve");
        vm.stopPrank();

        // Test approve to zero address should revert
        bytes memory expectedError = abi.encodeWithSignature(
            "ERC20InvalidSpender(address)", 
            address(0)
        );
        vm.expectRevert(expectedError);
        stableCoin.approve(address(0), amount);
    }

    function testFuzzingTransfer(uint256 amount) public {
        vm.assume(amount <= type(uint256).max - stableCoin.totalSupply());
        
        // Setup: mint tokens to user
        stableCoin.mint(user, amount);
        
        vm.startPrank(user);
        bool success = stableCoin.transfer(spender, amount);
        assertTrue(success, "Transfer should succeed");
        assertEq(stableCoin.balanceOf(spender), amount, "Wrong recipient balance after transfer");
        assertEq(stableCoin.balanceOf(user), 0, "Wrong sender balance after transfer");
        vm.stopPrank();
    }

    function testFuzzingApproveAndTransferFrom(uint256 amount) public {
        vm.assume(amount <= type(uint256).max - stableCoin.totalSupply());
        
        // Setup: mint tokens to user
        stableCoin.mint(user, amount);
        
        // Approve
        vm.prank(user);
        bool success = stableCoin.approve(spender, amount);
        assertTrue(success, "Approve should succeed");
        
        // TransferFrom
        vm.prank(spender);
        success = stableCoin.transferFrom(user, spender, amount);
        assertTrue(success, "TransferFrom should succeed");

        // Check allowance - if amount was type(uint256).max, allowance should remain unchanged
        uint256 expectedAllowance = amount == type(uint256).max ? type(uint256).max : 0;
        assertEq(stableCoin.allowance(user, spender), expectedAllowance, "Wrong allowance after transferFrom");
        assertEq(stableCoin.balanceOf(spender), amount, "Wrong recipient balance after transferFrom");
        assertEq(stableCoin.balanceOf(user), 0, "Wrong sender balance after transferFrom");
    }
}
