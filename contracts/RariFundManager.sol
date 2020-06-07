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
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";

import "./lib/RariFundController.sol";
import "./RariFundToken.sol";

/**
 * @title RariFundManager
 * @dev This contract is the primary contract powering RariFund.
 * Anyone can deposit to the fund with deposit(string currencyCode, uint256 amount)
 * Anyone can withdraw their funds (with interest) from the fund with withdraw(string currencyCode, uint256 amount)
 */
contract RariFundManager is Ownable {
    using SafeMath for uint256;
    using SignedSafeMath for int256;

    /**
     * @dev Boolean that, if true, disables deposits to and withdrawals from this RariFundManager.
     */
    bool private _fundDisabled;

    /**
     * @dev Address of the RariFundToken.
     */
    address private _rariFundTokenContract;

    /**
     * @dev Address of the rebalancer.
     */
    address private _rariFundRebalancerAddress;

    /**
     * @dev Maps ERC20 token contract addresses to their currency codes.
     */
    string[] private _supportedCurrencies;

    /**
     * @dev Maps ERC20 token contract addresses to their currency codes.
     */
    mapping(string => address) private _erc20Contracts;

    /**
     * @dev Maps arrays of supported pools to currency codes.
     */
    mapping(string => uint8[]) private _poolsByCurrency;

    /**
     * @dev Struct for a pending withdrawal.
     */
    struct PendingWithdrawal {
        address payee;
        uint256 amount;
    }

    /**
     * @dev Mapping of withdrawal queues to currency codes.
     */
    mapping(string => PendingWithdrawal[]) private _withdrawalQueues;

    /**
     * @dev Constructor that sets supported ERC20 token contract addresses and supported pools for each supported token.
     */
    constructor () public {
        // Set master beneficiary of interest fees
        setInterestFeeMasterBeneficiary(msg.sender);

        // Add currencies
        addCurrency("DAI", 0x6B175474E89094C44Da98b954EedeAC495271d0F);
        addPoolToCurrency("DAI", 0); // dYdX
        addPoolToCurrency("DAI", 1); // Compound
        addCurrency("USDC", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        addPoolToCurrency("USDC", 0); // dYdX
        addPoolToCurrency("USDC", 1); // Compound
        addCurrency("USDT", 0xdAC17F958D2ee523a2206206994597C13D831ec7);
        addPoolToCurrency("USDT", 1); // Compound
    }

    /**
     * @dev Sets supported ERC20 token contract addresses for each supported token.
     * @param currencyCode The currency code of the token.
     * @param erc20Contract The ERC20 contract of the token.
     */
    function addCurrency(string memory currencyCode, address erc20Contract) internal {
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
     * @dev Emitted when the RariFundToken of the RariFundManager is set.
     */
    event FundTokenSet(address newContract);

    /**
     * @dev Emitted when the rebalancer of the RariFundManager is set.
     */
    event FundRebalancerSet(address newAddress);

    /**
     * @dev Upgrades RariFundManager.
     * Passes data to the new contract, sets the new RariFundToken minter, and forwards tokens from the old to the new.
     * @param newContract The address of the new RariFundManager contract.
     */
    function upgradeFundManager(address newContract) external onlyOwner {
        // Pass data to the new contract
        FundManagerData[] memory data = new FundManagerData[](_supportedCurrencies.length);

        for (uint256 i = 0; i < _supportedCurrencies.length; i++) data[i] = FundManagerData(
            _netDeposits[_supportedCurrencies[i]],
            _netExchanges[_supportedCurrencies[i]],
            _rawInterestAccruedAtLastFeeRateChange[_supportedCurrencies[i]],
            _interestFeesGeneratedAtLastFeeRateChange[_supportedCurrencies[i]],
            _interestFeesClaimed[_supportedCurrencies[i]]
        );

        RariFundManager(newContract).setFundManagerData(_supportedCurrencies, data);

        // Update RariFundToken minter
        if (_rariFundTokenContract != address(0)) {
            RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
            rariFundToken.addMinter(newContract);
            rariFundToken.renounceMinter();
        }

        // Withdraw all tokens from all pools, process pending withdrawals, and transfer them to new FundManager
        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            string memory currencyCode = _supportedCurrencies[i];

            for (uint256 j = 0; j < _poolsByCurrency[currencyCode].length; j++)
                if (RariFundController.getPoolBalance(_poolsByCurrency[currencyCode][j], _erc20Contracts[currencyCode]) > 0)
                    RariFundController.withdrawAllFromPool(_poolsByCurrency[currencyCode][j], _erc20Contracts[currencyCode]);

            processPendingWithdrawals(_supportedCurrencies[i]);

            ERC20 token = ERC20(_erc20Contracts[currencyCode]);
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) require(token.transfer(newContract, balance), "Failed to transfer tokens to new FundManager.");
        }

        emit FundManagerUpgraded(newContract);
    }

    /**
     * @dev Old fund manager contract authorized to migrate its data to the new one.
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
     * @dev Struct for a pending withdrawal.
     */
    struct FundManagerData {
        int256 netExchanges;
        int256 netDeposits;
        uint256 rawInterestAccruedAtLastFeeRateChange;
        uint256 interestFeesGeneratedAtLastFeeRateChange;
        uint256 interestFeesClaimed;
    }

    /**
     * @dev Upgrades RariFundManager.
     * Receives data from the old contract.
     * @param supportedCurrencies To initialize all variables below.
     * @param data Array of data by currency.
     */
    function setFundManagerData(string[] calldata supportedCurrencies, FundManagerData[] calldata data) external {
        require(_authorizedFundManagerDataSource != address(0) && msg.sender == _authorizedFundManagerDataSource, "Caller is not an authorized source.");
        require(supportedCurrencies.length > 0, "Array of supported currencies not supplied.");
        require(supportedCurrencies.length == data.length, "Mismatch between length of supported currencies and data array.");
        
        for (uint256 i = 0; i < supportedCurrencies.length; i++) {
            _netDeposits[supportedCurrencies[i]] = data[i].netDeposits;
            _netExchanges[supportedCurrencies[i]] = data[i].netExchanges;
            _rawInterestAccruedAtLastFeeRateChange[supportedCurrencies[i]] = data[i].rawInterestAccruedAtLastFeeRateChange;
            _interestFeesGeneratedAtLastFeeRateChange[supportedCurrencies[i]] = data[i].interestFeesGeneratedAtLastFeeRateChange;
            _interestFeesClaimed[supportedCurrencies[i]] = data[i].interestFeesClaimed;
        }
    }

    /**
     * @dev Sets or upgrades the RariFundToken of the RariFundManager.
     * @param newContract The address of the new RariFundToken contract.
     */
    function setFundToken(address newContract) external onlyOwner {
        _rariFundTokenContract = newContract;
        emit FundTokenSet(newContract);
    }

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
     * @dev Emitted when deposits to and withdrawals from this RariFundManager have been disabled.
     */
    event FundDisabled();

    /**
     * @dev Emitted when deposits to and withdrawals from this RariFundManager have been enabled.
     */
    event FundEnabled();

    /**
     * @dev Disables deposits to and withdrawals from this RariFundManager so contract(s) can be upgraded.
     */
    function disableFund() external onlyOwner {
        require(!_fundDisabled, "Fund already disabled.");
        _fundDisabled = true;
        emit FundDisabled();
    }

    /**
     * @dev Enables deposits to and withdrawals from this RariFundManager once contract(s) are upgraded.
     */
    function enableFund() external onlyOwner {
        require(_fundDisabled, "Fund already enabled.");
        _fundDisabled = false;
        emit FundEnabled();
    }

    /**
     * @notice Returns an account's total balance in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     * @param account The account whose balance we are calculating.
     */
    function usdBalanceOf(address account) external returns (uint256) {
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        if (rftTotalSupply == 0) return 0;
        uint256 rftBalance = rariFundToken.balanceOf(account);
        uint256 totalUsdBalance = this.getCombinedUsdBalance();
        uint256 accountUsdBalance = rftBalance.mul(totalUsdBalance).div(rftTotalSupply);
        return accountUsdBalance;
    }

    /**
     * @dev Returns the fund's raw total balance (investor funds + unclaimed fees) of the specified currency.
     * Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by RariFundController.getPoolBalance) potentially modifies the state.
     * @param currencyCode The currency code of the balance to be calculated.
     */
    function getRawTotalBalance(string memory currencyCode) internal returns (uint256) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        ERC20 token = ERC20(erc20Contract);
        uint256 totalBalance = token.balanceOf(address(this));
        for (uint256 i = 0; i < _poolsByCurrency[currencyCode].length; i++) totalBalance = totalBalance.add(RariFundController.getPoolBalance(_poolsByCurrency[currencyCode][i], erc20Contract));
        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) totalBalance = totalBalance.sub(_withdrawalQueues[currencyCode][i].amount);

        return totalBalance;
    }

    /**
     * @notice Returns the fund's total balance of all currencies in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     */
    function getCombinedUsdBalance() public returns (uint256) {
        uint256 totalBalance = 0;

        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            string memory currencyCode = _supportedCurrencies[i];
            ERC20Detailed token = ERC20Detailed(_erc20Contracts[currencyCode]);
            uint256 tokenDecimals = token.decimals();
            uint256 balance = getTotalBalance(_supportedCurrencies[i]);
            uint256 balanceUsd = 18 >= tokenDecimals ? balance.mul(10 ** (uint256(18).sub(tokenDecimals))) : balance.div(10 ** (tokenDecimals.sub(18))); // TODO: Factor in prices; for now we assume the value of all supported currencies = $1
            totalBalance = totalBalance.add(balanceUsd);
        }

        return totalBalance;
    }

    /**
     * @dev Fund balance limit in USD per Ethereum address.
     */
    uint256 private _accountBalanceLimitUsd;

    /**
     * @dev Sets or upgrades the account balance limit in USD.
     * @param accountBalanceLimitUsd The fund balance limit in USD per Ethereum address.
     */
    function setAccountBalanceLimitUsd(uint256 accountBalanceLimitUsd) external onlyOwner {
        _accountBalanceLimitUsd = accountBalanceLimitUsd;
    }

    /**
     * @dev Fund balance limit in USD per Ethereum address.
     */
    mapping(string => bool) private _acceptedCurrencies;

    /**
     * @notice Returns a boolean indicating if `currencyCode` is currently accepted.
     * @param currencyCode The currency code to mark as accepted or not accepted.
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
    event Deposit(string indexed currencyCode, address indexed sender, uint256 amount);

    /**
     * @dev Emitted when funds have been withdrawn from RariFund.
     */
    event Withdrawal(string indexed currencyCode, address indexed payee, uint256 amount);

    /**
     * @dev Emitted when funds have been queued for withdrawal from RariFund.
     */
    event WithdrawalQueued(string indexed currencyCode, address indexed payee, uint256 amount);

    /**
     * @notice Deposits funds to RariFund in exchange for RFT.
     * Please note that you must approve RariFundManager to transfer of the necessary amount of tokens.
     * @param currencyCode The current code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     * @return Boolean indicating success.
     */
    function deposit(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(!_fundDisabled, "Deposits to and withdrawals from the fund are currently disabled.");
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(isCurrencyAccepted(currencyCode), "This currency is not currently accepted; please convert your funds to an accepted currency before depositing.");

        ERC20Detailed token = ERC20Detailed(erc20Contract);
        uint256 tokenDecimals = token.decimals();
        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 rftAmount = 0;
        uint256 amountUsd = 18 >= tokenDecimals ? amount.mul(10 ** (uint256(18).sub(tokenDecimals))) : amount.div(10 ** (tokenDecimals.sub(18)));

        if (rftTotalSupply > 0) rftAmount = amountUsd.mul(rftTotalSupply).div(this.getCombinedUsdBalance());
        else rftAmount = amountUsd;

        require(this.usdBalanceOf(msg.sender).add(amountUsd) <= _accountBalanceLimitUsd, "Making this deposit would cause this account's balance to exceed the maximum."); // TODO: Improve performance by not calling getCombinedUsdBalance() twice

        // Make sure the user must approve the transfer of tokens before calling the deposit function
        require(token.transferFrom(msg.sender, address(this), amount), "Failed to transfer input tokens.");
        _netDeposits[currencyCode] = _netDeposits[currencyCode].add(int256(amount));
        require(rariFundToken.mint(msg.sender, rftAmount), "Failed to mint output tokens.");
        emit Deposit(currencyCode, msg.sender, amount);
        return true;
    }

    /**
     * @notice Withdraws funds from RariFund in exchange for RFT.
     * Please note that you must approve RariFundManager to burn of the necessary amount of RFT.
     * @param currencyCode The current code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdraw(string calldata currencyCode, uint256 amount) external returns (bool) {
        require(!_fundDisabled, "Deposits to and withdrawals from the fund are currently disabled.");
        require(_rariFundTokenContract != address(0), "RariFundToken contract not set.");
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");

        ERC20Detailed token = ERC20Detailed(erc20Contract);
        uint256 tokenDecimals = token.decimals();
        uint256 contractBalance = token.balanceOf(address(this));

        RariFundToken rariFundToken = RariFundToken(_rariFundTokenContract);
        uint256 rftTotalSupply = rariFundToken.totalSupply();
        uint256 totalUsdBalance = this.getCombinedUsdBalance();
        uint256 amountUsd = 18 >= tokenDecimals ? amount.mul(10 ** (uint256(18).sub(tokenDecimals))) : amount.div(10 ** (tokenDecimals.sub(18)));
        uint256 rftAmount = amountUsd.mul(rftTotalSupply).div(totalUsdBalance);
        require(rftAmount <= rariFundToken.balanceOf(msg.sender), "Your RFT balance is too low for a withdrawal of this amount.");
        require(amountUsd <= totalUsdBalance, "Fund balance is too low for a withdrawal of this amount.");

        // Make sure the user must approve the burning of tokens before calling the withdraw function
        rariFundToken.burnFrom(msg.sender, rftAmount);
        _netDeposits[currencyCode] = _netDeposits[currencyCode].sub(int256(amount));

        if (amount <= contractBalance) {
            require(token.transfer(msg.sender, amount), "Failed to transfer output tokens.");
            emit Withdrawal(currencyCode, msg.sender, amount);
        } else  {
            _withdrawalQueues[currencyCode].push(PendingWithdrawal(msg.sender, amount));
            emit WithdrawalQueued(currencyCode, msg.sender, amount);
        }

        return true;
    }

    /**
     * @dev Processes pending withdrawals in the queue for the specified currency.
     * @param currencyCode The currency code of the token for which to process pending withdrawals.
     * @return Boolean indicating success.
     */
    function processPendingWithdrawals(string memory currencyCode) public returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        ERC20 token = ERC20(erc20Contract);
        uint256 balanceHere = token.balanceOf(address(this));
        uint256 total = 0;
        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) total = total.add(_withdrawalQueues[currencyCode][i].amount);
        if (total > balanceHere) revert("Not enough balance to process pending withdrawals.");

        for (uint256 i = 0; i < _withdrawalQueues[currencyCode].length; i++) {
            require(token.transfer(_withdrawalQueues[currencyCode][i].payee, _withdrawalQueues[currencyCode][i].amount), "Failed to transfer tokens.");
            emit Withdrawal(currencyCode, _withdrawalQueues[currencyCode][i].payee, _withdrawalQueues[currencyCode][i].amount);
        }

        _withdrawalQueues[currencyCode].length = 0;
        return true;
    }

    /**
     * @notice Returns the number of pending withdrawals in the queue of the specified currency.
     * @param currencyCode The currency code of the pending withdrawals.
     */
    function countPendingWithdrawals(string calldata currencyCode) external view returns (uint256) {
        return _withdrawalQueues[currencyCode].length;
    }

    /**
     * @notice Returns the payee of a pending withdrawal of the specified currency.
     * @param currencyCode The currency code of the pending withdrawal.
     * @param index The index of the pending withdrawal.
     */
    function getPendingWithdrawalPayee(string calldata currencyCode, uint256 index) external view returns (address) {
        return _withdrawalQueues[currencyCode][index].payee;
    }

    /**
     * @notice Returns the amount of a pending withdrawal of the specified currency.
     * @param currencyCode The currency code of the pending withdrawal.
     * @param index The index of the pending withdrawal.
     */
    function getPendingWithdrawalAmount(string calldata currencyCode, uint256 index) external view returns (uint256) {
        return _withdrawalQueues[currencyCode][index].amount;
    }

    /**
     * @dev Approves tokens to the pool without spending gas on every deposit.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be approved.
     * @param amount The amount of tokens to be approved.
     * @return Boolean indicating success.
     */
    function approveToPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.approveToPool(pool, erc20Contract, amount), "Pool approval failed.");
        return true;
    }

    /**
     * @dev Deposits funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be deposited.
     * @param amount The amount of tokens to be deposited.
     * @return Boolean indicating success.
     */
    function depositToPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.depositToPool(pool, erc20Contract, amount), "Pool deposit failed.");
        return true;
    }

    /**
     * @dev Withdraws funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The currency code of the token to be withdrawn.
     * @param amount The amount of tokens to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdrawFromPool(uint8 pool, string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.withdrawFromPool(pool, erc20Contract, amount), "Pool withdrawal failed.");
        return true;
    }

    /**
     * @dev Withdraws all funds from any supported pool.
     * @param pool The name of the pool.
     * @param currencyCode The ERC20 contract of the token to be withdrawn.
     * @return Boolean indicating success.
     */
    function withdrawAllFromPool(uint8 pool, string calldata currencyCode) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.withdrawAllFromPool(pool, erc20Contract), "Pool withdrawal failed.");
        return true;
    }

    /**
     * @dev Approves tokens to 0x without spending gas on every deposit.
     * @param currencyCode The currency code of the token to be approved.
     * @param amount The amount of tokens to be approved.
     * @return Boolean indicating success.
     */
    function approveTo0x(string calldata currencyCode, uint256 amount) external onlyRebalancer returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(RariFundController.approveTo0x(erc20Contract, amount), "0x approval failed.");
        return true;
    }

    /**
     * @dev Fills 0x exchange orders up to a certain amount of input and up to a certain price.
     * We should be able to make this function external and use calldata for all parameters, but Solidity does not support calldata structs (https://github.com/ethereum/solidity/issues/5479).
     * @param inputCurrencyCode The currency code to be sold.
     * @param outputCurrencyCode The currency code to be bought.
     * @param orders The limit orders to be filled in ascending order of price.
     * @param signatures The signatures for the orders.
     * @param takerAssetFillAmount The amount of the taker asset to sell (excluding taker fees).
     * @return Boolean indicating success.
     */
    function fill0xOrdersUpTo(string memory inputCurrencyCode, string memory outputCurrencyCode, LibOrder.Order[] memory orders, bytes[] memory signatures, uint256 takerAssetFillAmount) public payable onlyRebalancer returns (bool) {
        uint256[2] memory filledAmounts = RariFundController.fill0xOrdersUpTo(orders, signatures, takerAssetFillAmount);
        require(filledAmounts[0] > 0, "Filling orders via 0x failed.");
        _netExchanges[inputCurrencyCode] = _netExchanges[inputCurrencyCode].add(int256(filledAmounts[0]));
        _netExchanges[outputCurrencyCode] = _netExchanges[outputCurrencyCode].sub(int256(filledAmounts[1]));
        return true;
    }
    
    /**
     * @notice Returns the fund's total investor balance (combined balance of all users of the fund; unlike getRawTotalBalance, excludes unclaimed interest fees) of the specified currency.
     * @param currencyCode The currency code of the balance to be calculated.
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     */
    function getTotalBalance(string memory currencyCode) public returns (uint256) {
        return getRawTotalBalance(currencyCode).sub(getInterestFeesUnclaimed(currencyCode));
    }

    /**
     * @dev Maps the net quantity of deposits (i.e., deposits - withdrawals) to each currency code.
     * On deposit, amount deposited is added to _netDeposits[currencyCode]; on withdrawal, amount withdrawn is subtracted from _netDeposits[currencyCode].
     */
    mapping(string => int256) private _netDeposits;

    /**
     * @dev Maps the net quantity of exchanges (i.e., sold - bought) to each currency code.
     * On exchange to another currency, amount exchanged is added to _netExchanges[currencyCode]; on exchange from another currency, amount exchanged is subtracted from _netExchanges[currencyCode].
     */
    mapping(string => int256) private _netExchanges;
    
    /**
     * @notice Returns the raw total amount of interest accrued by the fund as a whole (including the fees paid on interest).
     * @param currencyCode The currency code of the interest to be calculated.
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     */
    function getRawInterestAccrued(string memory currencyCode) public returns (uint256) {
        int256 rawInterestAccrued = int256(getRawTotalBalance(currencyCode)).sub(_netDeposits[currencyCode]).add(_netExchanges[currencyCode]).add(int256(_interestFeesClaimed[currencyCode]));
        return rawInterestAccrued > 0 ? uint256(rawInterestAccrued) : 0;
    }
    
    /**
     * @notice Returns the amount of interest accrued by investors (excluding the fees taken on interest).
     * @param currencyCode The currency code of the interest to be calculated.
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     */
    function getInterestAccrued(string memory currencyCode) public returns (uint256) {
        int256 interestAccrued = int256(getTotalBalance(currencyCode)).sub(_netDeposits[currencyCode]).add(_netExchanges[currencyCode]);
        return interestAccrued > 0 ? uint256(interestAccrued) : 0;
    }

    /**
     * @notice Returns the amount of interest accrued by investors across all currencies in USD (scaled by 1e18).
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     */
    function getCombinedUsdInterestAccrued() public returns (uint256) {
        uint256 totalInterest = 0;

        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            string memory currencyCode = _supportedCurrencies[i];
            ERC20Detailed token = ERC20Detailed(_erc20Contracts[currencyCode]);
            uint256 tokenDecimals = token.decimals();
            uint256 interest = getInterestAccrued(_supportedCurrencies[i]);
            uint256 interestUsd = 18 >= tokenDecimals ? interest.mul(10 ** (uint256(18).sub(tokenDecimals))) : interest.div(10 ** (tokenDecimals.sub(18))); // TODO: Factor in prices; for now we assume the value of all supported currencies = $1
            totalInterest = totalInterest.add(interestUsd);
        }

        return totalInterest;
    }

    /**
     * @dev The proportion of interest accrued that is taken as a service fee (scaled by 1e18).
     */
    uint256 private _interestFeeRate;

    /**
     * @dev Sets the fee rate on interest.
     * @param rate The proportion of interest accrued to be taken as a service fee (scaled by 1e18).
     */
    function setInterestFeeRate(uint256 rate) external onlyOwner {
        require(rate != _interestFeeRate, "This is already the current interest fee rate.");

        for (uint256 i = 0; i < _supportedCurrencies.length; i++) {
            string memory currencyCode = _supportedCurrencies[i];
            if (getInterestFeesUnclaimed(currencyCode) > 0) this.claimFees(currencyCode);
            _interestFeesGeneratedAtLastFeeRateChange[currencyCode] = getInterestFeesGenerated(currencyCode); // MUST update this first before updating _rawInterestAccruedAtLastFeeRateChange since it depends on it 
            _rawInterestAccruedAtLastFeeRateChange[currencyCode] = getRawInterestAccrued(currencyCode);
        }

        _interestFeeRate = rate;
    }

    /**
     * @dev Returns the fee rate on interest.
     */
    function getInterestFeeRate() public view returns (uint256) {
        return _interestFeeRate;
    }

    /**
     * @dev The amount of interest accrued at the time of the most recent change to the fee rate.
     */
    mapping(string => uint256) private _rawInterestAccruedAtLastFeeRateChange;

    /**
     * @dev The amount of fees generated on interest at the time of the most recent change to the fee rate.
     */
    mapping(string => uint256) private _interestFeesGeneratedAtLastFeeRateChange;

    /**
     * @notice Returns the amount of interest fees accrued by beneficiaries.
     * @param currencyCode The currency code of the interest fees to be calculated.
     * @dev Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     */
    function getInterestFeesGenerated(string memory currencyCode) public returns (uint256) {
        int256 rawInterestAccruedSinceLastFeeRateChange = int256(getRawInterestAccrued(currencyCode)).sub(int256(_rawInterestAccruedAtLastFeeRateChange[currencyCode]));
        int256 interestFeesGeneratedSinceLastFeeRateChange = rawInterestAccruedSinceLastFeeRateChange.mul(int256(_interestFeeRate)).div(1e18);
        int256 interestFeesGenerated = int256(_interestFeesGeneratedAtLastFeeRateChange[currencyCode]).add(interestFeesGeneratedSinceLastFeeRateChange);
        return interestFeesGenerated > 0 ? uint256(interestFeesGenerated) : 0;
    }

    /**
     * @dev The total claimed amount of interest fees (shared + unshared).
     */
    mapping(string => uint256) private _interestFeesClaimed;

    /**
     * @dev Returns the total unclaimed amount of interest fees (shared + unshared).
     * @param currencyCode The currency code of the unclaimed interest fees to be calculated.
     * Ideally, we can add the view modifier, but Compound's getUnderlyingBalance function (called by getRawTotalBalance) potentially modifies the state.
     */
    function getInterestFeesUnclaimed(string memory currencyCode) internal returns (uint256) {
        int256 interestFeesUnclaimed = int256(getInterestFeesGenerated(currencyCode)).sub(int256(_interestFeesClaimed[currencyCode]));
        return interestFeesUnclaimed > 0 ? uint256(interestFeesUnclaimed) : 0;
    }

    /**
     * @dev The master beneficiary of fees on interest; i.e., the recipient of all unshared fees on interest.
     */
    address private _interestFeeMasterBeneficiary;

    /**
     * @dev Sets the master beneficiary of interest fees.
     * @param beneficiary The master beneficiary of fees on interest; i.e., the recipient of all unshared fees on interest.
     */
    function setInterestFeeMasterBeneficiary(address beneficiary) public onlyOwner {
        require(beneficiary != address(0), "Interest fee master beneficiary cannot be the zero address.");
        _interestFeeMasterBeneficiary = beneficiary;
    }

    /**
     * @dev Emitted when fees on interest are withdrawn.
     */
    event InterestFeesClaimed(string currencyCode, address beneficiary, uint256 amount);

    /**
     * @dev Withdraws all accrued fees on interest to the master beneficiary.
     * @param currencyCode The currency code of the interest fees to be claimed.
     * @return Boolean indicating success.
     */
    function claimFees(string calldata currencyCode) external returns (bool) {
        address erc20Contract = _erc20Contracts[currencyCode];
        require(erc20Contract != address(0), "Invalid currency code.");
        require(_interestFeeMasterBeneficiary != address(0), "Master beneficiary cannot be the zero address.");
        uint256 feesToClaim = getInterestFeesUnclaimed(currencyCode);
        require(feesToClaim > 0, "No new fees are available to claim.");
        _interestFeesClaimed[currencyCode] = _interestFeesClaimed[currencyCode].add(feesToClaim);
        require(ERC20(erc20Contract).transfer(_interestFeeMasterBeneficiary, feesToClaim), "Failed to transfer fees to beneficiary.");
        emit InterestFeesClaimed(currencyCode, _interestFeeMasterBeneficiary, feesToClaim);
        return true;
    }
}
