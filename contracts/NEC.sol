pragma solidity ^0.4.11;

import "./MiniMeToken.sol";

/*
    Copyright 2017, Will Harborne (Ethfinex)
*/

contract NEC is MiniMeToken {

  function NEC(
    address _tokenFactory,
    address efxVaultWallet
  ) MiniMeToken(
    _tokenFactory,
    0x0,                    // no parent token
    0,                      // no snapshot block number from parent
    "Ethfinex Nectar Token", // Token name
    18,                     // Decimals
    "NEC",                  // Symbol
    true                    // Enable transfers
    ) {
        generateTokens(efxVaultWallet, 100000000000000000000000);
        enableBurning(false);
    }

    // Flag that determines if the token can be burned for rewards or not
    bool public burningEnabled;


////////////////
// Enable token burning by users
////////////////

    function enableBurning(bool _burningEnabled) onlyController {
        burningEnabled = _burningEnabled;
    }

    function burnAndRetrieve(uint256 _tokensToBurn) returns (bool success) {
        require(burningEnabled);

        uint256 previousBalanceFrom = balanceOfAt(msg.sender, block.number);
        if (previousBalanceFrom < _tokensToBurn) {
            return false;
        }

        // Alerts the token controller of the burn function call
        // If enabled, controller will distribute fees and destroy tokens
        // Or any other logic chosen by controller
        if (isContract(controller)) {
            require(TokenController(controller).onBurn(msg.sender, _tokensToBurn));
        }

        Burned(msg.sender, _tokensToBurn);
        return true;
    }

    event Burned(address indexed who, uint256 _amount);

}
