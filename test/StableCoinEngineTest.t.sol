// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoin.sol";
import "../src/StableCoinEngine.sol";
import "../src/proxy/StableCoinProxy.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MockCollateralToken is ERC20Upgradeable {
    function initialize() external initializer {
        __ERC20_init("Mock Token", "MTK");
        _mint(msg.sender, 1000000e18);
    }
}

contract StableCoinEngineTest is Test {
    StableCoin stableCoin;
    StableCoinEngine engine;
    MockCollateralToken collateral;
    ProxyAdmin proxyAdmin;
    StableCoinProxy stableCoinProxy;
    StableCoinProxy engineProxy;
    StableCoinEngine engineImpl;

    address owner = address(0x123);
    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(owner);

        // Deploy mock collateral token
        collateral = new MockCollateralToken();
        collateral.initialize();
        deal(address(collateral), user1, 1000e18);

        // Deploy implementation contracts
        engineImpl = new StableCoinEngine();
        stableCoin = new StableCoin();

        // Deploy proxies with empty initialization data
        engineProxy = new StableCoinProxy(
            address(engineImpl),
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
            address(collateral),
            address(stableCoinProxy),
            owner
        );

        // Set initial price
        StableCoinEngine(address(engineProxy)).updatePrice(1000e8); // $1000 per token

        vm.stopPrank();

        // Update references to use proxies
        stableCoin = StableCoin(address(stableCoinProxy));
        engine = StableCoinEngine(address(engineProxy));
    }

    function test_InitialState() public {
        assertEq(address(engine.collateralToken()), address(collateral));
        assertEq(address(engine.stableCoin()), address(stableCoinProxy));
        assertEq(engine.owner(), owner);
        assertEq(stableCoin.owner(), owner);
    }

    function test_Deposit() public {
        uint256 depositAmount = 100e18;
        
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), depositAmount);
        engine.deposit(depositAmount);
        vm.stopPrank();
        
        (uint256 collateralAmount, , , ) = engine.positions(user1);
        assertEq(collateralAmount, depositAmount);
        assertEq(collateral.balanceOf(address(engineProxy)), depositAmount);
    }

    function test_Mint() public {
        uint256 depositAmount = 100e18;
        uint256 mintAmount = 50e18;
        
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), depositAmount);
        engine.depositAndMint(depositAmount, mintAmount);
        vm.stopPrank();
        
        (uint256 collateralAmount, uint256 debtAmount, , ) = engine.positions(user1);
        assertEq(collateralAmount, depositAmount);
        assertEq(debtAmount, mintAmount);
        assertEq(stableCoin.balanceOf(user1), mintAmount);
    }

    function test_Burn() public {
        uint256 depositAmount = 100e18;
        uint256 mintAmount = 50e18;
        uint256 burnAmount = 30e18;
        
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), depositAmount);
        engine.depositAndMint(depositAmount, mintAmount);
        engine.burn(burnAmount);
        vm.stopPrank();
        
        (, uint256 debtAmount, , ) = engine.positions(user1);
        assertEq(debtAmount, mintAmount - burnAmount);
        assertEq(stableCoin.balanceOf(user1), mintAmount - burnAmount);
    }

    function test_Withdraw() public {
        uint256 depositAmount = 100e18;
        uint256 withdrawAmount = 50e18;
        
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), depositAmount);
        engine.deposit(depositAmount);
        engine.withdraw(withdrawAmount);
        vm.stopPrank();
        
        (uint256 collateralAmount, , , ) = engine.positions(user1);
        assertEq(collateralAmount, depositAmount - withdrawAmount);
        assertEq(collateral.balanceOf(address(engineProxy)), depositAmount - withdrawAmount);
        assertEq(collateral.balanceOf(user1), 1000e18 - depositAmount + withdrawAmount);
    }

    function test_BurnAndWithdraw() public {
        uint256 depositAmount = 100e18;
        uint256 mintAmount = 50e18;
        uint256 burnAmount = 30e18;
        uint256 withdrawAmount = 40e18;
        
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), depositAmount);
        engine.depositAndMint(depositAmount, mintAmount);
        engine.burnAndWithdraw(burnAmount, withdrawAmount);
        vm.stopPrank();
        
        (uint256 collateralAmount, uint256 debtAmount, , ) = engine.positions(user1);
        assertEq(collateralAmount, depositAmount - withdrawAmount);
        assertEq(debtAmount, mintAmount - burnAmount);
        assertEq(stableCoin.balanceOf(user1), mintAmount - burnAmount);
        assertEq(collateral.balanceOf(user1), 1000e18 - depositAmount + withdrawAmount);
    }

    function test_RevertOnInsufficientCollateral() public {
        // Set up initial state
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), 100e18);
        engine.deposit(100e18);
        
        // Calculate max debt allowed:
        // 100e18 collateral * 1000e8 price/token = 100_000e26 total value
        // 100_000e26 * 150/100 = 150_000e26 adjusted value
        // To maintain health factor >= 1e18:
        // (150_000e26 * 1e18) / debt = 1e18
        // debt = 150_000e26
        vm.expectRevert(abi.encodeWithSignature("InsufficientCollateral()"));
        engine.mint(150_001e18); // Try to mint more than allowed by collateral ratio
        vm.stopPrank();
    }

    function test_RevertOnInsufficientDebt() public {
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), 100e18);
        engine.deposit(100e18);
        engine.mint(50e18);
        
        vm.expectRevert(abi.encodeWithSignature("InsufficientDebt()"));
        engine.burn(51e18); // Try to burn more than minted
        vm.stopPrank();
    }

    function test_OnlyOwnerCanUpdatePrice() public {
        uint256 newPrice = 2000e8;
        
        vm.expectRevert("Ownable: caller is not the owner");
        engine.updatePrice(newPrice);
        
        vm.prank(owner);
        engine.updatePrice(newPrice);
        
        assertEq(engine.getTWAP(), newPrice);
    }
}
