// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant ETH_VALUE_IN_USD = 2000;
    uint256 public constant AMOUNT_MINTED_DSC = 10;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAdressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000$/ETH = 30000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 10000e18;
        // 2000$ / ETH, $10000
        uint256 actualAmount = 5e18;
        uint256 expectedAmount = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedAmount, actualAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetAccountCollateralValueInUsd() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 expectedUsd = AMOUNT_COLLATERAL * ETH_VALUE_IN_USD;
        uint256 actualUsd = dsce.getAccountCollateralValueInUsd(USER);
        assertEq(expectedUsd, actualUsd);
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
    }

    function testDepositAndMint() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED_DSC);
        uint256 expectedDeposited = AMOUNT_COLLATERAL * ETH_VALUE_IN_USD;
        uint256 expectedMinted = 10;

        uint256 actualDeposited = dsce.getAccountCollateralValueInUsd(USER);
        uint256 actualMinted = dsce.getAccountMinted(USER);
        vm.stopPrank();

        console.log(actualDeposited);
        console.log(actualMinted);

        assertEq(expectedDeposited, actualDeposited);
        assertEq(expectedMinted, actualMinted);
    }

    function testRedeemWhenUserHasNotDscMinted() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 expectedBalance = 10 ether;
        uint256 actualBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(expectedBalance, actualBalance);
    }

    function testBurnDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED_DSC);
        console.log(dsc.balanceOf(USER));
        dsce.burnDsc(AMOUNT_MINTED_DSC);
        vm.stopPrank();

        uint256 expectedBalance = 0;
        uint256 actualBalance = dsc.balanceOf(USER);

        assertEq(expectedBalance, actualBalance);
    }
}
