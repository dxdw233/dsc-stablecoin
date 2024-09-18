// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if

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
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                   depositCollateralAndMintDsc TESTS
    //////////////////////////////////////////////////////////////*/
    modifier depositCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED_DSC);
        vm.stopPrank();
        _;
    }

    function testCanMintWithCollateralDeposited() public depositCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_MINTED_DSC);
    }

    /*//////////////////////////////////////////////////////////////
                             mintDsc TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfMintAmountIsZero() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRedeemWhenUserHasNotDscMinted() public depositCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 expectedBalance = 10 ether;
        uint256 actualBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(expectedBalance, actualBalance);
    }

    function testCanMintDsc() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(AMOUNT_MINTED_DSC);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_MINTED_DSC);
    }
    /*//////////////////////////////////////////////////////////////
                             burnDsc TESTS
    //////////////////////////////////////////////////////////////*/

    function testCanBurnDsc() public depositCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.burnDsc(AMOUNT_MINTED_DSC);
        vm.stopPrank();

        uint256 expectedBalance = 0;
        uint256 actualBalance = dsc.balanceOf(USER);

        assertEq(expectedBalance, actualBalance);
    }

    function testRevertsIfBurnMoreThanUserHas() public {
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
        vm.stopPrank();
    }

    function testRevertIfBurnAmountIsZero() public depositCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         redeemCollateral TESTS
    //////////////////////////////////////////////////////////////*/
    function testCanRedeemCollateral() public depositCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 expectedBalance = 10 ether;
        uint256 actualBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(expectedBalance, actualBalance);
    }

    function testIfRedeemAmountIsZero() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateralForDsc() public depositCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_MINTED_DSC);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINTED_DSC);
        vm.stopPrank();

        uint256 expectedBalance = 10 ether;
        uint256 actualBalance = ERC20Mock(weth).balanceOf(USER);

        uint256 expectedMinted = 0;
        uint256 actualMinted = dsce.getAccountMinted(USER);

        assertEq(expectedBalance, actualBalance);
        assertEq(expectedMinted, actualMinted);
    }
}
