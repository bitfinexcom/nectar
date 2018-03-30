pragma solidity 0.4.21;

import "./NEC.sol";
import "./Whitelist.sol";
import "./SafeMath.sol";

/*
    Copyright 2018, Will Harborne (Ethfinex)
    v2.0.0
*/

contract NectarController is TokenController, Whitelist {
    using SafeMath for uint256;

    NEC public tokenContract;   // The new token for this Campaign
    address public vaultAddress;        // The address to hold the funds donated

    uint public periodLength = 30;       // Contribution windows length in days
    uint public startTime = 1518523865;  // Time of window 1 opening

    mapping (uint => uint) public windowFinalBlock;  // Final block before initialisation of new window


    /// @dev There are several checks to make sure the parameters are acceptable
    /// @param _vaultAddress The address that will store the donated funds
    /// @param _tokenAddress Address of the token contract this contract controls

    function NectarController(
        address _vaultAddress,
        address _tokenAddress
    ) public {
        require(_vaultAddress != 0);                // To prevent burning ETH
        tokenContract = NEC(_tokenAddress); // The Deployed Token Contract
        vaultAddress = _vaultAddress;
        windowFinalBlock[0] = 5082733;
        windowFinalBlock[1] = 5260326;
    }

    /// @dev The fallback function is called when ether is sent to the contract, it
    /// simply calls `doTakerPayment()` . No tokens are created when takers contribute.
    /// `_owner`. Payable is a required solidity modifier for functions to receive
    /// ether, without this modifier functions will throw if ether is sent to them

    function ()  public payable {
        doTakerPayment();
    }

    function contributeForMakers(address _owner) public payable authorised {
        doMakerPayment(_owner);
    }

/////////////////
// TokenController interface
/////////////////

    /// @notice `proxyPayment()` allows the caller to send ether to the Campaign
    /// but does not create tokens. This functions the same as the fallback function.
    /// @param _owner Does not do anything, but preserved because of MiniMe standard function.
    function proxyPayment(address _owner) public payable returns(bool) {
        doTakerPayment();
        return true;
    }

    /// @notice `proxyAccountingCreation()` allows owner to create tokens without sending ether via the contract
    /// Creates tokens, pledging an amount of eth to token holders but not sending it through the contract to the vault
    /// @param _owner The person who will have the created tokens
    function proxyAccountingCreation(address _owner, uint _pledgedAmount, uint _tokensToCreate) public onlyOwner returns(bool) {
        // Ethfinex is a hybrid decentralised exchange
        // This function is only for use to create tokens on behalf of users of the centralised side of Ethfinex
        // Because there are several different fee tiers (depending on trading volume) token creation rates may not always be proportional to fees contributed.
        // For example if a user is trading with a 0.025% fee as opposed to the standard 0.1% the tokensToCreate the pledged fees will be lower than through using the standard contributeForMakers function
        // Tokens to create must be calculated off-chain using the issuance equation and current parameters of this contract, multiplied depending on user's fee tier
        doProxyAccounting(_owner, _pledgedAmount, _tokensToCreate);
        return true;
    }


    /// @notice Notifies the controller about a transfer.
    /// Transfers can only happen to whitelisted addresses
    /// @param _from The origin of the transfer
    /// @param _to The destination of the transfer
    /// @param _amount The amount of the transfer
    /// @return False if the controller does not authorize the transfer
    function onTransfer(address _from, address _to, uint _amount) public returns(bool) {
        if (isRegistered(_to) && isRegistered(_from)) {
          return true;
        } else {
          return false;
        }
    }

    /// @notice Notifies the controller about an approval, for this Campaign all
    ///  approvals are allowed by default and no extra notifications are needed
    /// @param _owner The address that calls `approve()`
    /// @param _spender The spender in the `approve()` call
    /// @param _amount The amount in the `approve()` call
    /// @return False if the controller does not authorize the approval
    function onApprove(address _owner, address _spender, uint _amount) public
        returns(bool)
    {
        if (isRegistered(_owner)) {
          return true;
        } else {
          return false;
        }
    }

    /// @notice Notifies the controller about a burn attempt. Initially all burns are disabled.
    /// Upgraded Controllers in the future will allow token holders to claim the pledged ETH
    /// @param _owner The address that calls `burn()`
    /// @param _tokensToBurn The amount in the `burn()` call
    /// @return False if the controller does not authorize the approval
    function onBurn(address _owner, uint _tokensToBurn) public
        returns(bool)
    {
        // This plugin can only be called by the token contract
        require(msg.sender == address(tokenContract));

        uint256 feeTotal = tokenContract.totalPledgedFees();
        uint256 totalTokens = tokenContract.totalSupply();
        uint256 feeValueOfTokens = (feeTotal.mul(_tokensToBurn)).div(totalTokens);

        // Destroy the owners tokens prior to sending them the associated fees
        require (tokenContract.destroyTokens(_owner, _tokensToBurn));
        require (address(this).balance >= feeValueOfTokens);
        require (_owner.send(feeValueOfTokens));

        emit LogClaim(_owner, feeValueOfTokens);
        return true;
    }

/////////////////
// Maker and taker fee payments handling
/////////////////


    /// @dev `doMakerPayment()` is an internal function that sends the ether that this
    ///  contract receives to the `vault` and creates tokens in the address of the
    ///  `_owner`who the fee contribution was sent by
    /// @param _owner The address that will hold the newly created tokens
    function doMakerPayment(address _owner) internal {

        require ((tokenContract.controller() != 0) && (msg.value != 0) );
        tokenContract.pledgeFees(msg.value);
        require (vaultAddress.send(msg.value));

        // Set the block number which will be used to calculate issuance rate during
        // this window if it has not already been set
        if(windowFinalBlock[currentWindow()-1] == 0) {
            windowFinalBlock[currentWindow()-1] = block.number -1;
        }

        uint256 newIssuance = getFeeToTokenConversion(msg.value);
        require (tokenContract.generateTokens(_owner, newIssuance));

        emit LogContributions (_owner, msg.value, true);
        return;
    }

    /// @dev `doTakerPayment()` is an internal function that sends the ether that this
    ///  contract receives to the `vault`, creating no tokens
    function doTakerPayment() internal {

        require ((tokenContract.controller() != 0) && (msg.value != 0) );
        tokenContract.pledgeFees(msg.value);
        require (vaultAddress.send(msg.value));

        emit LogContributions (msg.sender, msg.value, false);
        return;
    }

    /// @dev `doProxyAccounting()` is an internal function that creates tokens
    /// for fees pledged by the owner
    function doProxyAccounting(address _owner, uint _pledgedAmount, uint _tokensToCreate) internal {

        require ((tokenContract.controller() != 0));
        if(windowFinalBlock[currentWindow()-1] == 0) {
            windowFinalBlock[currentWindow()-1] = block.number -1;
        }
        tokenContract.pledgeFees(_pledgedAmount);

        if(_tokensToCreate > 0) {
            uint256 newIssuance = getFeeToTokenConversion(_pledgedAmount);
            require (tokenContract.generateTokens(_owner, _tokensToCreate));
        }

        emit LogContributions (msg.sender, _pledgedAmount, true);
        return;
    }

    /// @notice `onlyOwner` changes the location that ether is sent
    /// @param _newVaultAddress The address that will store the fees collected
    function setVault(address _newVaultAddress) public onlyOwner {
        vaultAddress = _newVaultAddress;
    }

    /// @notice `onlyOwner` can upgrade the controller contract
    /// @param _newControllerAddress The address that will have the token control logic
    function upgradeController(address _newControllerAddress) public onlyOwner {
        tokenContract.changeController(_newControllerAddress);
        emit UpgradedController(_newControllerAddress);
    }

/////////////////
// Issuance reward related functions - upgraded by changing controller
/////////////////

    /// @dev getFeeToTokenConversion (v2) - Controller could be changed in the future to update this function
    /// @param _contributed - The value of fees contributed during the window
    function getFeeToTokenConversion(uint256 _contributed) public view returns (uint256) {

        uint calculationBlock = windowFinalBlock[currentWindow()-1];
        uint256 previousSupply = tokenContract.totalSupplyAt(calculationBlock);
        uint256 initialSupply = tokenContract.totalSupplyAt(windowFinalBlock[0]);
        // Rate = 1000 * (2-totalSupply/InitialSupply)^2
        // This imposes a max possible supply of 2 billion
        if (previousSupply >= 2 * initialSupply) {
            return 0;
        }
        uint256 newTokens = _contributed.mul(1000).mul(bigInt(2)-(bigInt(previousSupply).div(initialSupply))).mul(bigInt(2)-(bigInt(previousSupply).div(initialSupply))).div(bigInt(1).mul(bigInt(1)));
        return newTokens;
    }

    function bigInt(uint256 input) internal pure returns (uint256) {
      return input.mul(10 ** 10);
    }

    function currentWindow() public constant returns (uint) {
       return windowAt(block.timestamp);
    }

    function windowAt(uint timestamp) public constant returns (uint) {
      return timestamp < startTime
          ? 0
          : timestamp.sub(startTime).div(periodLength * 1 days) + 1;
    }

    /// @dev topUpBalance - This is only used to increase this.balance in the case this controller is used to allow burning
    function topUpBalance() public payable {
        // Pledged fees could be sent here and used to payout users who burn their tokens
        emit LogFeeTopUp(msg.value);
    }

    /// @dev evacuateToVault - This is only used to evacuate remaining to ether from this contract to the vault address
    function evacuateToVault() public onlyOwner{
        vaultAddress.transfer(address(this).balance);
        emit LogFeeEvacuation(address(this).balance);
    }

    /// @dev enableBurning - Allows the owner to activate burning on the underlying token contract
    function enableBurning(bool _burningEnabled) public onlyOwner{
        tokenContract.enableBurning(_burningEnabled);
    }


//////////
// Safety Methods
//////////

    /// @notice This method can be used by the owner to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    function claimTokens(address _token) public onlyOwner {

        NEC token = NEC(_token);
        uint balance = token.balanceOf(this);
        token.transfer(owner, balance);
        emit ClaimedTokens(_token, owner, balance);
    }

////////////////
// Events
////////////////
    event ClaimedTokens(address indexed _token, address indexed _controller, uint _amount);

    event LogFeeTopUp(uint _amount);
    event LogFeeEvacuation(uint _amount);
    event LogContributions (address _user, uint _amount, bool _maker);
    event LogClaim (address _user, uint _amount);

    event UpgradedController (address newAddress);

}
