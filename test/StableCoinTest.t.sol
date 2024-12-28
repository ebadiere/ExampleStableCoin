// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoin.sol";
import "../src/StableCoinEngine.sol";
import "../src/proxy/StableCoinProxy.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract StableCoinTest is Test {
    StableCoin stableCoin;
    StableCoinEngine engine;
    ProxyAdmin proxyAdmin;
    StableCoinProxy stableCoinProxy;
    StableCoinProxy engineProxy;

    address owner = address(0x123);
    address user = address(0x1);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin();

        // Deploy implementation contracts
        stableCoin = new StableCoin();
        engine = new StableCoinEngine();

        // Deploy proxies with empty initialization data
        engineProxy = new StableCoinProxy(
            address(engine),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        stableCoinProxy = new StableCoinProxy(
            address(stableCoin),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        // Initialize contracts in the correct order
        vm.startPrank(owner);
        
        StableCoin(address(stableCoinProxy)).initialize(
            "StableCoin",
            "SC",
            address(engineProxy),
            owner
        );

        StableCoinEngine(address(engineProxy)).initialize(
            address(0x2), // Mock collateral token
            address(stableCoinProxy),
            owner
        );

        vm.stopPrank();

        // Update references to use proxies
        stableCoin = StableCoin(address(stableCoinProxy));
        engine = StableCoinEngine(address(engineProxy));
    }

    function testInitialization() public {
        assertEq(stableCoin.name(), "StableCoin");
        assertEq(stableCoin.symbol(), "SC");
        assertEq(stableCoin.engine(), address(engineProxy));
        assertEq(stableCoin.owner(), owner);
    }

    function testMint() public {
        uint256 amount = 100e18;
        
        vm.prank(address(engineProxy));
        stableCoin.mint(user, amount);
        
        assertEq(stableCoin.balanceOf(user), amount);
    }

    function testBurn() public {
        uint256 amount = 100e18;
        
        // First mint some tokens
        vm.prank(address(engineProxy));
        stableCoin.mint(user, amount);
        
        // Then burn them
        vm.prank(address(engineProxy));
        stableCoin.burn(user, amount);
        
        assertEq(stableCoin.balanceOf(user), 0);
    }

    function testTransfer() public {
        uint256 amount = 100e18;
        address recipient = address(0x2);
        
        // First mint some tokens
        vm.prank(address(engineProxy));
        stableCoin.mint(user, amount);
        
        // Then transfer them
        vm.prank(user);
        stableCoin.transfer(recipient, amount);
        
        assertEq(stableCoin.balanceOf(user), 0);
        assertEq(stableCoin.balanceOf(recipient), amount);
    }

    function testApprove() public {
        uint256 amount = 100e18;
        address spender = address(0x2);
        
        vm.prank(user);
        stableCoin.approve(spender, amount);
        
        assertEq(stableCoin.allowance(user, spender), amount);
    }

    function testTransferFrom() public {
        uint256 amount = 100e18;
        address spender = address(0x2);
        address recipient = address(0x3);
        
        // First mint some tokens
        vm.prank(address(engineProxy));
        stableCoin.mint(user, amount);
        
        // Then approve spender
        vm.prank(user);
        stableCoin.approve(spender, amount);
        
        // Then transfer from user to recipient
        vm.prank(spender);
        stableCoin.transferFrom(user, recipient, amount);
        
        assertEq(stableCoin.balanceOf(user), 0);
        assertEq(stableCoin.balanceOf(recipient), amount);
        assertEq(stableCoin.allowance(user, spender), 0);
    }

    function testFuzzingTransfer(uint256 amount) public {
        vm.assume(amount > 0);
        address recipient = address(0x2);
        
        vm.prank(address(engineProxy));
        stableCoin.mint(user, amount);
        
        vm.prank(user);
        stableCoin.transfer(recipient, amount);
        
        assertEq(stableCoin.balanceOf(user), 0);
        assertEq(stableCoin.balanceOf(recipient), amount);
    }

    function testFuzzingApproveAndTransferFrom(uint256 amount) public {
        vm.assume(amount > 0 && amount < type(uint256).max);
        address spender = address(0x2);
        address recipient = address(0x3);
        
        vm.prank(address(engineProxy));
        stableCoin.mint(user, amount);
        
        vm.prank(user);
        stableCoin.approve(spender, amount);
        
        vm.prank(spender);
        stableCoin.transferFrom(user, recipient, amount);
        
        assertEq(stableCoin.balanceOf(user), 0);
        assertEq(stableCoin.balanceOf(recipient), amount);
        assertEq(stableCoin.allowance(user, spender), 0);
    }

    function test_OnlyEngineMint() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("OnlyEngine()"));
        stableCoin.mint(user, 100e18);
        vm.stopPrank();
    }

    function test_OnlyEngineBurn() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSignature("OnlyEngine()"));
        stableCoin.burn(user, 100e18);
        vm.stopPrank();
    }

    function test_BurnExceedsBalance() public {
        uint256 amount = 100e18;
        
        vm.prank(address(engineProxy));
        stableCoin.mint(user, amount);
        
        vm.prank(address(engineProxy));
        vm.expectRevert("ERC20: burn amount exceeds balance");
        stableCoin.burn(user, amount + 1);
    }
}
