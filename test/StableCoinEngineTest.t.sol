// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoinEngine.sol";
import "../src/StableCoin.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract StableCoinEngineTest is Test {
    StableCoinEngine public engine;
    StableCoin public stableCoin;
    MockERC20 public collateral;
    address public owner;

    event Update(uint256 currentPrice);
    event TWAP(uint256 twap);

    function setUp() public {
        owner = address(this);
        collateral = new MockERC20();
        stableCoin = new StableCoin(owner);
        engine = new StableCoinEngine(
            address(stableCoin),
            address(collateral),
            owner
        );
    }

    function testInitialState() public {
        assertEq(engine.stableCoin(), address(stableCoin));
        assertEq(engine.collateralToken(), address(collateral));
        assertEq(engine.PERIOD(), 1 hours);
    }

    function testUpdate() public {
        uint256 price = 1000; // $1000 per token
        
        // First, tell Forge what event data to expect
        vm.expectEmit(address(engine));
        emit Update(price);
        
        // Then call the function that should emit the event
        engine.update(price);
        
        (uint256 timestamp, uint256 storedPrice) = engine.observations(0);
        assertEq(storedPrice, price);
        assertEq(timestamp, block.timestamp);
    }

    function testTWAPSingleObservation() public {
        uint256 price = 1000;
        engine.update(price);
        
        // With a single observation, TWAP should revert as we need at least 2 observations
        vm.expectRevert();
        engine.getTWAP();
    }

    function testTWAPMultipleObservations() public {
        // First observation
        engine.update(1000);
        
        // Move forward 30 minutes and add second observation
        vm.warp(block.timestamp + 30 minutes);
        engine.update(2000);
        
        // Move forward another 30 minutes and add third observation
        vm.warp(block.timestamp + 30 minutes);
        engine.update(3000);
        
        // Expected TWAP: ((1000 * 30 minutes) + (2000 * 30 minutes)) / (60 minutes) = 1500
        uint256 expectedTWAP = 1500;
        
        // First, tell Forge what event data to expect
        vm.expectEmit(address(engine));
        emit TWAP(expectedTWAP);
        
        // Then call the function that should emit the event
        uint256 twap = engine.getTWAP();
        assertEq(twap, expectedTWAP);
    }
}
