/**
 * @file
 * @author David Lucid <david@rari.capital>
 *
 * @section LICENSE
 *
 * All rights reserved to David Lucid of David Lucid LLC.
 * Any disclosure, reproduction, distribution or other use of this code by any individual or entity other than David Lucid of David Lucid LLC, unless given explicit permission by David Lucid of David Lucid LLC, is prohibited.
 *
 * @section DESCRIPTION
 *
 * This file includes the Ethereum contract code for RariFundManager, the primary contract powering Rari Capital's RariFund.
 */

pragma solidity ^0.5.7;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/drafts/SignedSafeMath.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";

import "@0x/contracts-exchange-libs/contracts/src/LibOrder.sol";

import "./RariFundController.sol";
import "./RariFundToken.sol";
import "./RariFundProxy.sol";

/**
 * @title RariFundManager
 * @dev This contract is the primary contract powering RariFund.
 * Anyone can deposit to the fund with deposit(string currencyCode, uint256 amount).
 * Anyone can withdraw their funds (with interest) from the fund with withdraw(string currencyCode, uint256 amount).
 */
contract RariFundManager is Ownable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeERC20 for IERC20;

    /**
     * @dev Boolean that, if true, disables the primary functionality of this RariFundManager.
     */
    bool private _fundDisabled;

    /**
     * @dev Address of the RariFundController.
     */
    address payable private _rariFundControllerContract;

    /**
     * @dev Contract of the RariFundController.
     */
    RariFundController private _rariFundController;

    /**
     * @dev Address of the RariFundToken.
     */
    address private _rariFundTokenContract;

    /**
     * @dev Contract of the RariFundToken.
     */
    RariFundToken private _rariFundToken;

    /**
     * @dev Address of the RariFundProxy.
     */
    address private _rariFundProxyContract;

    /**
     * @dev Address of the rebalancer.
     */
    address private _rariFundRebalancerAddress;

    /**
     * @dev Array of currencies supported by the fund.
     */
    string[] private _supportedCurrencies;

    /**
     * @dev Maps ERC20 token contract addresses to supported currency codes.
     */
    mapping(string => address) private _erc20Contracts;

    /**
     * @dev Maps arrays of supported pools to currency codes.
     */
    mapping(string => uint8[]) private _poolsByCurrency;

    /**
     * @dev Constructor that sets supported ERC20 token contract addresses and supported pools for each supported token.
     */
    constructor () public {
        // Add supported currencies
        addSupportedCurrency("DAI", 0x6B175474E89094C44Da98b954EedeAC495271d0F);
        addPoolToCurrency("DAI", 0); // dYdX
        addPoolToCurrency("DAI", 1); // Compound
        addSupportedCurrency("USDC", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        addPoolToCurrency("USDC", 0); // dYdX
        addPoolToCurrency("USDC", 1); // Compound
        addSupportedCurrency("USDT", 0xdAC17F958D2ee523a2206206994597C13D831ec7);
        addPoolToCurrency("USDT", 1); // Compound
    }

    /**
     * @dev Marks a token as supported by the fund and stores its ERC20 contract address.
     * @param currencyCode The currency code of the token.
     * @param erc20Contract The ERC20 contract of the token.
     */
    function addSupportedCurrency(string memory currencyCode, address erc20Contract) internal {
        _supportedCurrencies.push(currencyCode);
        _erc20Contracts[currencyCode] = erc20Contract;
    }

    /**
     * @dev Adds a supported pool for a token.
     * @param currencyCode The currency code of the token.
     * @param pool Pool ID to be supported.
     */
    function addPoolToCurrency(string memory currencyCode, uint8 pool) internal {
        _poolsByCurrency[currencyCode].push(pool);
    }

    /**
     * @dev Emitted when RariFundManager is upgraded.
     */
    event FundManagerUpgraded(address newContract);

    /**
     * @dev Upgrades RariFundManager.
     * Sends data to the new contract, sets the new RariFundToken minter, and forwards tokens from the old to the new.
     * @param newContract The address of the new RariFundManager contract.
     */
    function upgradeFundManager(address newContract) external onlyOwner {
        // Pass data to the new contract
        FundManagerData memory data;

        data = FundManagerData(
            _netDeposits,
            _rawInterestAccruedAtLastFeeRateChange,
            _interestFeesGeneratedAtLastFeeRateChange,
            _interestFeesClaimed
        );

        RariFundManager(newContract).setFundManagerData(data);

        // Update RariFundToken minter
        if (_rariFundTokenContract != address(0)) {
            _rariFundToken.addMinter(newContract);
            _rariFundToken.renounceMinter();
        }

        emit FundManagerUpgraded(newContract);
    }

    /**
     * @dev Old RariFundManager contract authorized to migrate its data to the new one.
     */
    address private _authorizedFundManagerDataSource;

    /**
     * @dev Upgrades RariFundManager.
     * Authorizes the source for fund manager data (i.e., the old fund manager).
     * @param authorizedFundManagerDataSource Authorized source for data (i.e., the old fund manager).
     */
    function authorizeFundManagerDataSource(address authorizedFundManagerDataSource) external onlyOwner {
        _authorizedFundManagerDataSource = authorizedFundManagerDataSource;
    }

    /**
     * @dev Struct for data to transfer from the old RariFundManager to the new one.
     */
    struct FundManagerData {
        int256 netDeposits;
        int256 rawInterestAccruedAtLastFeeRateChange;
        int256 interestFeesGeneratedAtLastFeeRateChange;
        uint256 interestFeesClaimed;
    }

    /**
     * @dev Upgrades RariFundManager.
     * Sets data receieved from the old contract.
     * @param data The data from the old contract necessary to initialize the new contract.
     */
    function setFundManagerData(FundManagerData calldata data) external {
        require(_authorizedFundManagerDataSource != address(0) && msg.sender == _authorizedFundManagerDataSource, "Caller is not an authorized source.");
        _netDeposits = data.netDeposits;
        _rawInterestAccruedAtLastFeeRateChange = data.rawInterestAccruedAtLastFeeRateChange;
        _interestFeesGeneratedAtLastFeeRateChange = data.interestFeesGeneratedAtLastFeeRateChange;
        _interestFeesClaimed = data.interestFeesClaimed;
        _interestFeeRate = RariFundManager(_authorizedFundManagerDataSource).getInterestFeeRate();
    }

    /**
     * @dev Emitted when the RariFundController of the RariFundManager is set or upgraded.
     */
    event FundControllerSet(address newContract);

    /**
     * @dev Sets or upgrades RariFundController by forwarding tokens from the old to the new.
     * @param newContract The address of the new RariFundController contract.
     */
    function setFundController(address payable newContract) external onlyOwner cacheDydxBalances {
        // Forward tokens to new FundController if we are upgrading an existing one
        if (_rariFundControllerContract != address(0)) {
            for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
                string memory currencyCode = _supportedCurrencies[i];

                for (uint256 j = 0; j < _poolsByCurrency[currencyCode].length; j++)
                    if (getPoolBalance(_poolsByCurrency[currencyCode][j], currencyCode) > 0)
                        _rariFundController.withdrawAllFromPoolOnUpgrade(_poolsByCurrency[currencyCode][j], currencyCode); // No need to update the cached dYdX balances as they won't be used again

                IERC20 token = IERC20(_erc20Contracts[currencyCode]);
                uint256 balance = token.balanceOf(_rariFundControllerContract);
                if (balance > 0) token.safeTransferFrom(_rariFundControllerContract, newContract, balance);
            }
        }

        // Set new contract address
        _rariFundControllerContract = newContract;
        _rariFundController = RariFundController(_rariFundControllerContract);
        emit FundControllerSet(newContract);
    }

    /**
     * @dev Forwards tokens in the fund manager to the fund controller (for upgrading from v1.0.0 and for accidental transfers to the fund manager).
     */
    function forwardToFundController() external onlyOwner {
        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            IERC20 token = IERC20(_erc20Contracts[_supportedCurrencies[i]]);
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) token.safeTransfer(_rariFundControllerContract, balance);
        }
    }

    /**
     * @dev Emitted when the RariFundToken of the RariFundManager is set.
     */
    event FundTokenSet(address newContract);

    /**
     * @dev Sets or upgrades the RariFundToken of the RariFundManager.
     * @param newContract The address of the new RariFundToken contract.
     */
    function setFundToken(address newContract) external onlyOwner {
        _rariFundTokenContract = newContract;
        _rariFundToken = RariFundToken(_rariFundTokenContract);
        emit FundTokenSet(newContract);
    }

    /**
     * @dev Throws if called by any account other than the RariFundToken.
     */
    modifier onlyToken() {
        require(_rariFundTokenContract == msg.sender, "Caller is not the RariFundToken.");
        _;
    }

    /**
     * @dev Maps net quantity of deposits to the fund (i.e., deposits - withdrawals) to each user.
     * On deposit, amount deposited is added to `_netDepositsByAccount`; on withdrawal, amount withdrawn is subtracted from `_netDepositsByAccount`.
     */
    mapping(address => int256) private _netDepositsByAccount;

    /**
     * @dev Initializes `_netDepositsByAccount` after a fund manager upgrade.
     * @param accounts An array of accounts.
     * @param netDeposits An array of net deposits for each of `accounts`.
     */
    function initNetDeposits(address[] calldata accounts, int256[] calldata netDeposits) external onlyOwner {
        require(accounts.length > 0 && accounts.length == netDeposits.length, "Input arrays cannot be empty and must be the same length.");
        for (uint256 i = 0; i < accounts.length; i++) _netDepositsByAccount[accounts[i]] = netDeposits[i];
    }

    /**
     * @dev Recieves data about an RFT transfer or burn from RariFundToken so we can record it in `_netDepositsByAccount`.
     * @param sender The sender of the RFT.
     * @param recipient The recipient of the RFT (the zero address if burning).
     * @param rftAmount The amount of RFT transferred or burnt.
     * @param newRftTotalSupply The total supply of RFT after the transfer or burn.
     */
    function onFundTokenTransfer(address sender, address recipient, uint256 rftAmount, uint256 newRftTotalSupply) external fundEnabled onlyToken {
        if (rftAmount <= 0) return;
        uint256 oldRftTotalSupply = recipient == address(0) ? newRftTotalSupply.add(rftAmount) : newRftTotalSupply;
        uint256 amountUsd = rftAmount.mul(getFundBalance()).div(oldRftTotalSupply);
        _netDepositsByAccount[sender] = _netDepositsByAccount[sender].sub(int256(amountUsd));
        if (recipient == address(0)) _netDeposits = _netDeposits.sub(int256(amountUsd));
        else _netDepositsByAccount[recipient] = _netDepositsByAccount[recipient].add(int256(amountUsd));
    }

    /**
     * @notice Returns the total amount of interest accrued by `account` (excluding the fees paid on interest) in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     * @param account The account whose interest we are calculating.
     */
    function interestAccruedBy(address account) public returns (int256) {
        return int256(this.balanceOf(account)).sub(_netDepositsByAccount[account]);
    }

    /**
     * @dev Emitted when the RariFundProxy of the RariFundManager is set.
     */
    event FundProxySet(address newContract);

    /**
     * @dev Sets or upgrades the RariFundProxy of the RariFundManager.
     * @param newContract The address of the new RariFundProxy contract.
     */
    function setFundProxy(address newContract) external onlyOwner {
        _rariFundProxyContract = newContract;
        emit FundProxySet(newContract);
    }

    /**
     * @dev Throws if called by any account other than the RariFundProxy.
     */
    modifier onlyProxy() {
        require(_rariFundProxyContract == msg.sender, "Caller is not the RariFundProxy.");
        _;
    }

    /**
     * @dev Emitted when the rebalancer of the RariFundManager is set.
     */
    event FundRebalancerSet(address newAddress);

    /**
     * @dev Sets or upgrades the rebalancer of the RariFundManager.
     * @param newAddress The Ethereum address of the new rebalancer server.
     */
    function setFundRebalancer(address newAddress) external onlyOwner {
        _rariFundRebalancerAddress = newAddress;
        emit FundRebalancerSet(newAddress);
    }

    /**
     * @dev Throws if called by any account other than the rebalancer.
     */
    modifier onlyRebalancer() {
        require(_rariFundRebalancerAddress == msg.sender, "Caller is not the rebalancer.");
        _;
    }

    /**
     * @dev Emitted when the primary functionality of this RariFundManager contract has been disabled.
     */
    event FundDisabled();

    /**
     * @dev Emitted when the primary functionality of this RariFundManager contract has been enabled.
     */
    event FundEnabled();

    /**
     * @dev Disables primary functionality of this RariFundManager so contract(s) can be upgraded.
     */
    function disableFund() external onlyOwner {
        require(!_fundDisabled, "Fund already disabled.");
        _fundDisabled = true;
        emit FundDisabled();
    }

    /**
     * @dev Enables primary functionality of this RariFundManager once contract(s) are upgraded.
     */
    function enableFund() external onlyOwner {
        require(_fundDisabled, "Fund already enabled.");
        _fundDisabled = false;
        emit FundEnabled();
    }

    /**
     * @dev Throws if fund is disabled.
     */
    modifier fundEnabled() {
        require(!_fundDisabled, "This fund manager contract is disabled. This may be due to an upgrade.");
        _;
    }

    /**
     * @dev Boolean indicating if return values of `getPoolBalance` are to be cached.
     */
    bool _cachePoolBalances = false;

    /**
     * @dev Boolean indicating if dYdX balances returned by `getPoolBalance` are to be cached.
     */
    bool _cacheDydxBalances = false;

    /**
     * @dev Maps cached pool balances to pool indexes to currency codes.
     */
    mapping(string => mapping(uint8 => uint256)) _poolBalanceCache;

    /**
     * @dev Cached array of dYdX token addresses.
     */
    address[] private _dydxTokenAddressesCache;

    /**
     * @dev Cached array of dYdX balances.
     */
    uint256[] private _dydxBalancesCache;

    /**
     * @dev Returns the fund controller's balance of the specified currency in the specified pool.
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `CompoundPoolController.getBalance`) potentially modifies the state.
     * @param pool The index of the pool.
     * @param currencyCode The currency code of the token.
     */
    function getPoolBalance(uint8 pool, string memory currencyCode) internal returns (uint256) {
        if (!_rariFundController.hasCurrencyInPool(pool, currencyCode)) return 0;

        if (_cachePoolBalances || _cacheDydxBalances) {
            if (pool == 0) {
                address erc20Contract = _erc20Contracts[currencyCode];
                require(erc20Contract != address(0), "Invalid currency code.");
                if (_dydxBalancesCache.length == 0) (_dydxTokenAddressesCache, _dydxBalancesCache) = _rariFundController.getDydxBalances();
                for (uint256 i = 0; i < _dydxBalancesCache.length; i++) if (_dydxTokenAddressesCache[i] == erc20Contract) return _dydxBalancesCache[i];
                revert("Failed to get dYdX balance of this currency code.");
            } else if (_cachePoolBalances) {
                if (_poolBalanceCache[currencyCode][pool] == 0) _poolBalanceCache[currencyCode][pool] = _rariFundController._getPoolBalance(pool, currencyCode);
                return _poolBalanceCache[currencyCode][pool];
            }
        }

        return _rariFundController._getPoolBalance(pool, currencyCode);
    }

    /**
     * @dev Caches dYdX pool balances returned by `getPoolBalance` for the duration of the function.
     */
    modifier cacheDydxBalances() {
        bool cacheSetPreviously = _cacheDydxBalances;
        _cacheDydxBalances = true;
        _;

        if (!cacheSetPreviously) {
            _cacheDydxBalances = false;
            if (!_cachePoolBalances) _dydxBalancesCache.length = 0;
        }
    }

    /**
     * @dev Caches return values of `getPoolBalance` for the duration of the function.
     */
    modifier cachePoolBalances() {
        bool cacheSetPreviously = _cachePoolBalances;
        _cachePoolBalances = true;
        _;

        if (!cacheSetPreviously) {
            _cachePoolBalances = false;
            if (!_cacheDydxBalances) _dydxBalancesCache.length = 0;

            for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
                string memory currencyCode = _supportedCurrencies[i];
                for (uint256 j = 0; j < _poolsByCurrency[currencyCode].length; j++) _poolBalanceCache[currencyCode][_poolsByCurrency[currencyCode][j]] = 0;
            }
        }
    }

    /**
     * @notice Returns the fund's raw total balance (all RFT holders' funds + all unclaimed fees) of the specified currency.
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `RariFundController.getPoolBalance`) potentially modifies the state.
     * @param currencyCode The currency code of the balance to be calculated.
     */
    function getRawFundBalance(string memory currencyCode) public returns (uint256) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        IERC20 token = IERC20(erc20Contract);
        uint256 totalBalance = token.balanceOf(_rariFundControllerContract);
        for (uint256 i = 0; i < _poolsByCurrency[currencyCode].length; i++)
            totalBalance = totalBalance.add(getPoolBalance(_poolsByCurrency[currencyCode][i], currencyCode));

        return totalBalance;
    }

    /**
     * @dev Caches the fund's raw total balance (all RFT holders' funds + all unclaimed fees) of all currencies in USD (scaled by 1e18).
     */
    int256 private _rawFundBalanceCache = -1;

    /**
     * @notice Returns the fund's raw total balance (all RFT holders' funds + all unclaimed fees) of all currencies in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     */
    function getRawFundBalance() public cacheDydxBalances returns (uint256) {
        if (_rawFundBalanceCache >= 0) return uint256(_rawFundBalanceCache);

        uint256 totalBalance = 0;

        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            string memory currencyCode = _supportedCurrencies[i];
            uint256 balance = getRawFundBalance(currencyCode);
            address erc20Contract = _erc20Contracts[currencyCode];
            uint256 tokenDecimals = erc20Contract == 0xdAC17F958D2ee523a2206206994597C13D831ec7 ? 6 : ERC20Detailed(erc20Contract).decimals();
            uint256 balanceUsd = 18 >= tokenDecimals ? balance.mul(10 ** (uint256(18).sub(tokenDecimals))) : balance.div(10 ** (tokenDecimals.sub(18))); // TODO: Factor in prices; for now we assume the value of all supported currencies = $1
            totalBalance = totalBalance.add(balanceUsd);
        }

        return totalBalance;
    }

    /**
     * @dev Caches the value of getRawFundBalance() for the duration of the function.
     */
    modifier cacheRawFundBalance() {
        bool cacheSetPreviously = _rawFundBalanceCache >= 0;
        if (!cacheSetPreviously) _rawFundBalanceCache = int256(getRawFundBalance());
        _;
        if (!cacheSetPreviously) _rawFundBalanceCache = -1;
    }

    /**
     * @notice Returns the fund's total investor balance (all RFT holders' funds but not unclaimed fees) of all currencies in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     */
    function getFundBalance() public cacheRawFundBalance returns (uint256) {
        return getRawFundBalance().sub(getInterestFeesUnclaimed());
    }

    /**
     * @notice Returns an account's total balance in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     * @param account The account whose balance we are calculating.
     */
    function balanceOf(address account) external returns (uint256) {
        uint256 rftTotalSupply = _rariFundToken.totalSupply();
        if (rftTotalSupply == 0) return 0;
        uint256 rftBalance = _rariFundToken.balanceOf(account);
        uint256 fundBalanceUsd = getFundBalance();
        uint256 accountBalanceUsd = rftBalance.mul(fundBalanceUsd).div(rftTotalSupply);
        return accountBalanceUsd;
    }

    /**
     * @dev Fund balance limit in USD per Ethereum address.
     */
    uint256 private _accountBalanceLimitDefault;

    /**
     * @dev Sets or upgrades the default account balance limit in USD.
     * @param limitUsd The default fund balance limit per Ethereum address in USD.
     */
    function setDefaultAccountBalanceLimit(uint256 limitUsd) external onlyOwner {
        _accountBalanceLimitDefault = limitUsd;
    }

    /**
     * @dev Maps booleans indicating if Ethereum addresses are immune to the account balance limit.
     */
    mapping(address => int256) private _accountBalanceLimits;

    /**
     * @dev Sets the balance limit in USD of `account`.
     * @param account The Ethereum address to add or remove.
     * @param limitUsd The fund balance limit of `account` in USD. Use 0 to unset individual limit (and restore account to global limit). Use -1 to disable deposits from `account`.
     */
    function setIndividualAccountBalanceLimit(address account, int256 limitUsd) external onlyOwner {
        _accountBalanceLimits[account] = limitUsd;
    }

    /**
     * @dev Maps booleans indicating if currency codes are accepted for deposits.
     */
    mapping(string => bool) private _acceptedCurrencies;

    /**
     * @notice Returns a boolean indicating if deposits in `currencyCode` are currently accepted.
     * @param currencyCode The currency code to check.
     */
    function isCurrencyAccepted(string memory currencyCode) public view returns (bool) {
        return _acceptedCurrencies[currencyCode];
    }

    /**
     * @dev Marks `currencyCode` as accepted or not accepted.
     * @param currencyCode The currency code to mark as accepted or not accepted.
     * @param accepted A boolean indicating if the `currencyCode` is to be accepted.
     */
    function setAcceptedCurrency(string calldata currencyCode, bool accepted) external onlyRebalancer {
        _acceptedCurrencies[currencyCode] = accepted;
    }

    /**
     * @dev Emitted when funds have been deposited to RariFund.
     */
    event Deposit(string indexed currencyCode, address indexed sender, address indexed payee, uint256 amount, uint256 amountUsd, uint256 rftMinted);

    /**
     * @dev Emitted when funds have been withdrawn from RariFund.
     */
    event Withdrawal(string indexed currencyCode, address indexed sender, address indexed payee, uint256 amount, uint256 amountUsd, uint256 rftBurned);

    /**
     * @notice Internal function to deposit funds from `msg.sender` to RariFund in exchange for RFT minted to `to`.
     * You may only deposit currencies accepted by the fund (see `isCurrencyAccepted(string currencyCode)`).
     * Please note that you must approve RariFundManager to transfer at least `amount`.
     * @param to The address that will receieve the minted RFT.
     * @param currencyCode The currency code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     * @return Boolean indicating success.
     */
    function _depositTo(address to, string memory currencyCode, uint256 amount) internal fundEnabled returns (bool) {
        // Input validation
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(isCurrencyAccepted(currencyCode), "This currency is not currently accepted; please convert your funds to an accepted currency before depositing.");
        require(amount > 0, "Deposit amount must be greater than 0.");

        // Get deposit amount in USD
        uint256 tokenDecimals = erc20Contract == 0xdAC17F958D2ee523a2206206994597C13D831ec7 ? 6 : ERC20Detailed(erc20Contract).decimals();
        uint256 amountUsd = 18 >= tokenDecimals ? amount.mul(10 ** (uint256(18).sub(tokenDecimals))) : amount.div(10 ** (tokenDecimals.sub(18)));

        // Calculate RFT to mint
        uint256 rftTotalSupply = _rariFundToken.totalSupply();
        uint256 fundBalanceUsd = rftTotalSupply > 0 ? getFundBalance() : 0; // Only set if used
        uint256 rftAmount = 0;
        if (rftTotalSupply > 0 && fundBalanceUsd > 0) rftAmount = amountUsd.mul(rftTotalSupply).div(fundBalanceUsd);
        else rftAmount = amountUsd;
        require(rftAmount > 0, "Deposit amount is so small that no RFT would be minted.");

        // Check account balance limit if `to` is not whitelisted
        require(checkAccountBalanceLimit(to, amountUsd, rftTotalSupply, fundBalanceUsd), "Making this deposit would cause the balance of this account to exceed the maximum.");

        // Update net deposits, transfer funds from msg.sender, mint RFT, emit event, and return true
        _netDeposits = _netDeposits.add(int256(amountUsd));
        _netDepositsByAccount[to] = _netDepositsByAccount[to].add(int256(amountUsd));
        IERC20(erc20Contract).safeTransferFrom(msg.sender, _rariFundControllerContract, amount); // The user must approve the transfer of tokens beforehand
        require(_rariFundToken.mint(to, rftAmount), "Failed to mint output tokens.");
        emit Deposit(currencyCode, msg.sender, to, amount, amountUsd, rftAmount);
        return true;
    }

    /**
     * @dev Checks to make sure that, if `to` is not whitelisted, its balance will not exceed the maximum after depositing `amountUsd`.
     * This function was separated from the `_depositTo` function to avoid the stack getting too deep.
     * @param to The address that will receieve the minted RFT.
     * @param amountUsd The amount of tokens to be deposited in USD.
     * @param rftTotalSupply The total supply of RFT representing the fund's total investor balance.
     * @param fundBalanceUsd The fund's total investor balance in USD.
     * @return Boolean indicating success.
     */
    function checkAccountBalanceLimit(address to, uint256 amountUsd, uint256 rftTotalSupply, uint256 fundBalanceUsd) internal view returns (bool) {
        if (to != owner() && to != _interestFeeMasterBeneficiary) {
            if (_accountBalanceLimits[to] < 0) return false;
            uint256 initialBalanceUsd = rftTotalSupply > 0 && fundBalanceUsd > 0 ? _rariFundToken.balanceOf(to).mul(fundBalanceUsd).div(rftTotalSupply) : 0; // Save gas by reusing value of getFundBalance() instead of calling balanceOf
            uint256 accountBalanceLimitUsd = _accountBalanceLimits[to] > 0 ? uint256(_accountBalanceLimits[to]) : _accountBalanceLimitDefault;
            if (initialBalanceUsd.add(amountUsd) > accountBalanceLimitUsd) return false;
        }

        return true;
    }

    /**
     * @notice Deposits funds to RariFund in exchange for RFT.
     * You may only deposit currencies accepted by the fund (see `isCurrencyAccepted(string currencyCode)`).
     * Please note that you must approve RariFundManager to transfer at least `amount`.
     * @param currencyCode The currency code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     * @return Boolean indicating success.
     */
    function deposit(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(_depositTo(msg.sender, currencyCode, amount), "Deposit failed.");
        return true;
    }

    /**
     * @dev Deposits funds from `msg.sender` (RariFundProxy) to RariFund in exchange for RFT minted to `to`.
     * You may only deposit currencies accepted by the fund (see `isCurrencyAccepted(string currencyCode)`).
     * Please note that you must approve RariFundManager to transfer at least `amount`.
     * @param to The address that will receieve the minted RFT.
     * @param currencyCode The currency code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     * @return Boolean indicating success.
     */
    function depositTo(address to, string calldata currencyCode, uint256 amount) external onlyProxy returns (bool) {
        require(_depositTo(to, currencyCode, amount), "Deposit failed.");
        return true;
    }


    /**
     * @dev Returns the amount of RFT to burn for a withdrawal (used by `_withdrawFrom`).
     * @param from The address from which RFT will be burned.
     * @param amountUsd The amount of the withdrawal in USD
     */
    function getRftBurnAmount(address from, uint256 amountUsd) internal returns (uint256) {
        uint256 rftTotalSupply = _rariFundToken.totalSupply();
        uint256 fundBalanceUsd = getFundBalance();
        require(fundBalanceUsd > 0, "Fund balance is zero.");
        uint256 rftAmount = amountUsd.mul(rftTotalSupply).div(fundBalanceUsd);
        require(rftAmount <= _rariFundToken.balanceOf(from), "Your RFT balance is too low for a withdrawal of this amount.");
        require(rftAmount > 0, "Withdrawal amount is so small that no RFT would be burned.");
        return rftAmount;
    }

    /**
     * @dev Internal function to withdraw funds from RariFund to `msg.sender` in exchange for RFT burned from `from`.
     * You may only withdraw currencies held by the fund (see `getRawFundBalance(string currencyCode)`).
     * Please note that you must approve RariFundManager to burn of the necessary amount of RFT.
     * @param from The address from which RFT will be burned.
     * @param currencyCode The currency code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     * @return Boolean indicating success.
     */
    function _withdrawFrom(address from, string memory currencyCode, uint256 amount) internal fundEnabled cachePoolBalances returns (bool) {
        // Input validation
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(amount > 0, "Withdrawal amount must be greater than 0.");

        // Check contract balance of token and withdraw from pools if necessary
        IERC20 token = IERC20(erc20Contract);
        uint256 contractBalance = token.balanceOf(_rariFundControllerContract);

        for (uint256 i = 0; i < _poolsByCurrency[currencyCode].length; i++) {
            if (contractBalance >= amount) break;
            uint8 pool = _poolsByCurrency[currencyCode][i];
            uint256 poolBalance = getPoolBalance(pool, currencyCode);
            if (poolBalance <= 0) continue;
            uint256 amountLeft = amount.sub(contractBalance);
            uint256 poolAmount = amountLeft < poolBalance ? amountLeft : poolBalance;
            require(_rariFundController.withdrawFromPoolKnowingBalance(pool, currencyCode, poolAmount, poolBalance), "Pool withdrawal failed.");

            if (pool == 0) {
                for (uint256 j = 0; j < _dydxBalancesCache.length; j++) if (_dydxTokenAddressesCache[j] == erc20Contract) _dydxBalancesCache[j] = poolBalance.sub(amount);
            } else _poolBalanceCache[currencyCode][pool] = poolBalance.sub(amount);

            contractBalance = contractBalance.add(poolAmount);
        }

        require(amount <= contractBalance, "Available balance not enough to cover amount even after withdrawing from pools.");

        // Get withdrawal amount in USD
        uint256 tokenDecimals = erc20Contract == 0xdAC17F958D2ee523a2206206994597C13D831ec7 ? 6 : ERC20Detailed(erc20Contract).decimals();
        uint256 amountUsd = 18 >= tokenDecimals ? amount.mul(10 ** (uint256(18).sub(tokenDecimals))) : amount.div(10 ** (tokenDecimals.sub(18)));

        // Calculate RFT to burn
        uint256 rftAmount = getRftBurnAmount(from, amountUsd);

        // Burn RFT, transfer funds to msg.sender, update net deposits, emit event, and return true
        _rariFundToken.burnFrom(from, rftAmount); // The user must approve the burning of tokens beforehand
        token.safeTransferFrom(_rariFundControllerContract, msg.sender, amount);
        _netDeposits = _netDeposits.sub(int256(amountUsd));
        _netDepositsByAccount[from] = _netDepositsByAccount[from].sub(int256(amountUsd));
        emit Withdrawal(currencyCode, from, msg.sender, amount, amountUsd, rftAmount);
        return true;
    }

    /**
     * @notice Withdraws funds from RariFund in exchange for RFT.
     * You may only withdraw currencies held by the fund (see `getRawFundBalance(string currencyCode)`).
     * Please note that you must approve RariFundManager to burn of the necessary amount of RFT.
     * @param currencyCode The currency code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdraw(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(_withdrawFrom(msg.sender, currencyCode, amount), "Withdrawal failed.");
        return true;
    }

    /**
     * @dev Withdraws funds from RariFund to `msg.sender` (RariFundProxy) in exchange for RFT burned from `from`.
     * You may only withdraw currencies held by the fund (see `getRawFundBalance(string currencyCode)`).
     * Please note that you must approve RariFundManager to burn of the necessary amount of RFT.
     * @param from The address from which RFT will be burned.
     * @param currencyCode The currency code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdrawFrom(address from, string calldata currencyCode, uint256 amount) external onlyProxy returns (bool) {
        require(_withdrawFrom(from, currencyCode, amount), "Withdrawal failed.");
        return true;
    }

    /**
     * @dev Net quantity of deposits to the fund (i.e., deposits - withdrawals).
     * On deposit, amount deposited is added to `_netDeposits`; on withdrawal, amount withdrawn is subtracted from `_netDeposits`.
     */
    int256 private _netDeposits;
    
    /**
     * @notice Returns the raw total amount of interest accrued by the fund as a whole (including the fees paid on interest) in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     */
    function getRawInterestAccrued() public returns (int256) {
        return int256(getRawFundBalance()).sub(_netDeposits).add(int256(_interestFeesClaimed));
    }
    
    /**
     * @notice Returns the total amount of interest accrued by past and current RFT holders (excluding the fees paid on interest) in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     */
    function getInterestAccrued() public returns (int256) {
        return int256(getFundBalance()).sub(_netDeposits);
    }

    /**
     * @dev The proportion of interest accrued that is taken as a service fee (scaled by 1e18).
     */
    uint256 private _interestFeeRate;

    /**
     * @dev Returns the fee rate on interest.
     */
    function getInterestFeeRate() public view returns (uint256) {
        return _interestFeeRate;
    }

    /**
     * @dev Sets the fee rate on interest.
     * @param rate The proportion of interest accrued to be taken as a service fee (scaled by 1e18).
     */
    function setInterestFeeRate(uint256 rate) external fundEnabled onlyOwner cacheRawFundBalance {
        require(rate != _interestFeeRate, "This is already the current interest fee rate.");
        _depositFees();
        _interestFeesGeneratedAtLastFeeRateChange = getInterestFeesGenerated(); // MUST update this first before updating _rawInterestAccruedAtLastFeeRateChange since it depends on it 
        _rawInterestAccruedAtLastFeeRateChange = getRawInterestAccrued();
        _interestFeeRate = rate;
    }

    /**
     * @dev The amount of interest accrued at the time of the most recent change to the fee rate.
     */
    int256 private _rawInterestAccruedAtLastFeeRateChange;

    /**
     * @dev The amount of fees generated on interest at the time of the most recent change to the fee rate.
     */
    int256 private _interestFeesGeneratedAtLastFeeRateChange;

    /**
     * @notice Returns the amount of interest fees accrued by beneficiaries in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     */
    function getInterestFeesGenerated() public returns (int256) {
        int256 rawInterestAccruedSinceLastFeeRateChange = getRawInterestAccrued().sub(_rawInterestAccruedAtLastFeeRateChange);
        int256 interestFeesGeneratedSinceLastFeeRateChange = rawInterestAccruedSinceLastFeeRateChange.mul(int256(_interestFeeRate)).div(1e18);
        int256 interestFeesGenerated = _interestFeesGeneratedAtLastFeeRateChange.add(interestFeesGeneratedSinceLastFeeRateChange);
        return interestFeesGenerated;
    }

    /**
     * @dev The total claimed amount of interest fees.
     */
    uint256 private _interestFeesClaimed;

    /**
     * @dev Returns the total unclaimed amount of interest fees.
     * Ideally, we can add the view modifier, but Compound's `getUnderlyingBalance` function (called by `getRawFundBalance`) potentially modifies the state.
     */
    function getInterestFeesUnclaimed() public returns (uint256) {
        int256 interestFeesUnclaimed = getInterestFeesGenerated().sub(int256(_interestFeesClaimed));
        return interestFeesUnclaimed > 0 ? uint256(interestFeesUnclaimed) : 0;
    }

    /**
     * @dev The master beneficiary of fees on interest; i.e., the recipient of all fees on interest.
     */
    address private _interestFeeMasterBeneficiary;

    /**
     * @dev Sets the master beneficiary of interest fees.
     * @param beneficiary The master beneficiary of fees on interest; i.e., the recipient of all fees on interest.
     */
    function setInterestFeeMasterBeneficiary(address beneficiary) external fundEnabled onlyOwner {
        require(beneficiary != address(0), "Master beneficiary cannot be the zero address.");
        _interestFeeMasterBeneficiary = beneficiary;
    }

    /**
     * @dev Emitted when fees on interest are deposited back into the fund.
     */
    event InterestFeeDeposit(address beneficiary, uint256 amountUsd);

    /**
     * @dev Emitted when fees on interest are withdrawn.
     */
    event InterestFeeWithdrawal(address beneficiary, uint256 amountUsd, string currencyCode, uint256 amount);

    /**
     * @dev Internal function to deposit all accrued fees on interest back into the fund on behalf of the master beneficiary.
     * @return Integer indicating success (0), no fees to claim (1), or no RFT to mint (2).
     */
    function _depositFees() internal fundEnabled cacheRawFundBalance returns (uint8) {
        require(_interestFeeMasterBeneficiary != address(0), "Master beneficiary cannot be the zero address.");

        uint256 amountUsd = getInterestFeesUnclaimed();
        if (amountUsd <= 0) return 1;

        uint256 rftTotalSupply = _rariFundToken.totalSupply();
        uint256 rftAmount = 0;

        if (rftTotalSupply > 0) {
            uint256 fundBalanceUsd = getFundBalance();
            if (fundBalanceUsd > 0) rftAmount = amountUsd.mul(rftTotalSupply).div(fundBalanceUsd);
            else rftAmount = amountUsd;
        } else rftAmount = amountUsd;

        if (rftAmount <= 0) return 2;
        _interestFeesClaimed = _interestFeesClaimed.add(amountUsd);
        _netDeposits = _netDeposits.add(int256(amountUsd));
        _netDepositsByAccount[_interestFeeMasterBeneficiary] = _netDepositsByAccount[_interestFeeMasterBeneficiary].add(int256(amountUsd));
        require(_rariFundToken.mint(_interestFeeMasterBeneficiary, rftAmount), "Failed to mint output tokens.");
        emit Deposit("USD", _interestFeeMasterBeneficiary, _interestFeeMasterBeneficiary, amountUsd, amountUsd, rftAmount);

        emit InterestFeeDeposit(_interestFeeMasterBeneficiary, amountUsd);
        return 0;
    }

    /**
     * @notice Deposits all accrued fees on interest back into the fund on behalf of the master beneficiary.
     * @return Boolean indicating success.
     */
    function depositFees() external onlyRebalancer returns (bool) {
        uint8 result = _depositFees();
        require(result == 0, result == 2 ? "Deposit amount is so small that no RFT would be minted." : "No new fees are available to claim.");
    }

    /**
     * @notice Withdraws all accrued fees on interest to the master beneficiary.
     * @param currencyCode The currency code of the interest fees to be claimed.
     * @return Boolean indicating success.
     */
    function withdrawFees(string calldata currencyCode) external fundEnabled onlyRebalancer returns (bool) {
        require(_interestFeeMasterBeneficiary != address(0), "Master beneficiary cannot be the zero address.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        uint256 amountUsd = getInterestFeesUnclaimed();
        uint256 tokenDecimals = erc20Contract == 0xdAC17F958D2ee523a2206206994597C13D831ec7 ? 6 : ERC20Detailed(erc20Contract).decimals();
        uint256 amount = 18 >= tokenDecimals ? amountUsd.div(10 ** (uint256(18).sub(tokenDecimals))) : amountUsd.mul(10 ** (tokenDecimals.sub(18))); // TODO: Factor in prices; for now we assume the value of all supported currencies = $1
        require(amount > 0, "No new fees are available to claim.");

        _interestFeesClaimed = _interestFeesClaimed.add(amountUsd);
        IERC20(erc20Contract).safeTransferFrom(_rariFundControllerContract, _interestFeeMasterBeneficiary, amount);

        emit InterestFeeWithdrawal(_interestFeeMasterBeneficiary, amountUsd, currencyCode, amount);
        return true;
    }
}
