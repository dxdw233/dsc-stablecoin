// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Kaede
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stable coin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                             PRICE CONSTANT
    //////////////////////////////////////////////////////////////*/

    /// @notice The precison of the price feed
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    /// @notice The precision of the system
    uint256 private constant PRECISION = 1e18;

    /// @notice The threshold for liquidation
    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    /// @notice The precision of the liquidation threshold
    uint256 private constant LIQUIDATION_PRECISION = 100;

    /// @notice The minimum health factor
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    /// @notice The liquidation bonus
    uint256 private constant LIQUIDATION_BONUS = 10;

    /// @notice Mapping of token address to price feed address
    mapping(address token => address priceFeed) private s_priceFeed;

    /// @notice Mapping of user address to token address to amount of collateral deposited
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    /// @notice Mapping of user address to amount of DSC minted
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    /// @notice Array of collateral tokens address
    address[] private s_collateralTokens;

    /// @notice DSC contract
    DecentralizedStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event DSCMinted(address indexed user, uint256 amount);
    event DSCBurned(address user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TokenAdressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__DSCNotEnough();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /**
     * @notice Sets collateral, priceFeed, DSC contract addresses
     * @param tokenAddresses The addresses of approve collateral token contract
     * @param priceFeedAddresses The addresses of collateral token's pricefeed
     * @param dscAddress The address of DSC contract
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAdressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit collateral and mint DSC in one transaction
     * @param tokenCollateralAddress The address of collateral token contract
     * @param amountCollateral The amount of collateral token to deposit
     * @param amountToMint The amount of DSC to mint
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of the token to deposit as collateral
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit collateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Burn DSC and redeem collateral in one go
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral token
     * @param amountDscToBurn The amount of DSC to burn
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice Get back the collateral user has deposited
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral token
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        if (s_DSCMinted[msg.sender] > 0) {
            _revertIfHealthFactorBroken(msg.sender);
        }
    }

    /**
     * @notice User must have more collateral value than the minimum threshold
     * @param amountDscToMint The amount of DSC to mint
     * @dev This function should only be called by the DSC contract
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        if (s_DSCMinted[msg.sender] != 0) {
            _revertIfHealthFactorBroken(msg.sender);
        }
        s_DSCMinted[msg.sender] += amountDscToMint;
        emit DSCMinted(msg.sender, amountDscToMint);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice Burn DSC
     * @param amountDscToBurn The amount of DSC to burn
     */
    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) nonReentrant {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        if (s_DSCMinted[msg.sender] > 0) {
            _revertIfHealthFactorBroken(msg.sender);
        }
    }

    function liquidate(address collateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralAddress, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        if (s_DSCMinted[msg.sender] > 0) {
            _revertIfHealthFactorBroken(msg.sender);
        }
    }

    function getHealthFactor(address user) external view {}

    /*//////////////////////////////////////////////////////////////
                 INTERNAL/PRIVATE & VIEW/PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _burnDsc(uint256 amountToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Get user's amount of minted token and collateral value
     * @param user The address of the user
     * @return totalDscMinted The amount of minted token
     * @return collateralValueInUsd The total value of the collateral
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * @notice Get the health factor
     * @param user The address of user
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @notice Revert if health factor broken
     * @param user The address of user
     */
    function _revertIfHealthFactorBroken(address user) internal view {
        // 1. Check if the health factor is below 1
        // 2. If it is, revert
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                 EXTERNAL/PUBLIC & VIEW/PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice Get the value of user's collateral
     * @param user The address of user
     */
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    /**
     * @notice Get the token value in USD
     * @param token The contract address of token
     * @param amount The amount of token
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    /**
     * @notice Get total DSC user has minted
     * @param user The address of user
     */
    function getAccountMinted(address user) public view returns (uint256) {
        return s_DSCMinted[user];
    }
}
