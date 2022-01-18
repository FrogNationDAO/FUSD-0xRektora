// SPDX-License-Identifier: MIT

// 0xRektora

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import 'prb-math/contracts/PRBMathUD60x18.sol';
import './WUSD.sol';

interface IReserveOracle {
    function getExchangeRate(uint256 amount) external view returns (uint256);
}

/// @title King contract. Mint/Burn $WUSD against chosen assets
/// @author 0xRektora (https://github.com/0xRektora)
/// @notice Crown has the ability to add and disable reserve, which can be any ERC20 (stable/LP) given an oracle
/// that compute the exchange rates between $WUSD and the latter.
/// @dev Potential flaw of this tokenomics:
/// - Ability for the crown to change freely reserve parameters. (suggestion: immutable reserve/reserve parameter)
/// - Ability to withdraw assets and break the burning mechanism.
/// (suggestion: if reserve not immutable, compute a max amount withdrawable delta for a given reserve)
// TODO update vesting system
contract King {
    using PRBMathUD60x18 for uint256;
    using PRBMathUD60x18 for uint128;

    struct Reserve {
        uint128 mintingInterestRate; // In Bps
        uint128 burningTaxRate; // In Bps
        uint256 vestingPeriod;
        IReserveOracle reserveOracle;
        bool disabled;
        bool isReproveWhitelisted;
    }

    struct Vesting {
        uint256 unlockPeriod; // In block
        uint256 amount; // In WUSD
    }

    address public crown;
    WUSD public wusd;
    address public sWagmeKingdom;
    uint256 public sWagmeTaxRate; // In Bps

    address[] public reserveAddresses;
    address[] public reserveReproveWhitelistAddresses; // Array of whitelisted reserve accepted in reprove()
    mapping(address => Reserve) public reserves;
    mapping(address => Vesting) public vestings;

    mapping(address => uint256) public freeReserves; // In WUSD

    event RegisteredReserve(
        address indexed reserve,
        uint256 index,
        uint256 blockNumber,
        uint128 mintingInterestRate,
        uint128 burningTaxRate,
        uint256 vestingPeriod,
        address reserveOracle,
        bool disabled,
        bool isReproveWhitelisted // If this reserve can be used by users to reprove()
    );
    event Praise(address indexed reserve, address indexed to, uint256 amount);
    event Reprove(address indexed reserve, address indexed from, uint256 amount);
    event VestingRedeem(address indexed to, uint256 amount);
    event WithdrawReserve(address indexed reserve, address indexed to, uint256 amount);
    event UpdateReserveReproveWhitelistAddresses(address indexed reserve, bool newVal, bool created);

    modifier onlyCrown() {
        require(msg.sender == crown, 'King: Only crown can execute');
        _;
    }

    modifier reserveExists(address _reserve) {
        Reserve storage reserve = reserves[_reserve];
        require(address(reserve.reserveOracle) != address(0), "King: reserve doesn't exists");
        require(!reserve.disabled, 'King: reserve disabled');
        _;
    }

    constructor(
        address _wusd,
        address _sWagmeKingdom,
        uint256 _sWagmeTaxRate
    ) {
        crown = msg.sender;
        wusd = WUSD(_wusd);
        sWagmeKingdom = _sWagmeKingdom;
        sWagmeTaxRate = _sWagmeTaxRate;
    }

    /// @notice Returns the total number of reserves
    /// @return Length of [[reserveAddresses]]
    function reserveAddressesLength() external view returns (uint256) {
        return reserveAddresses.length;
    }

    /// @notice Returns the total number of whitelisted reserves for [[reprove()]]
    /// @return Length of [[reserveReproveWhitelistAddresses]]
    function reserveReproveWhitelistAddressesLength() external view returns (uint256) {
        return reserveReproveWhitelistAddresses.length;
    }

    /// @notice Use this function to create/change parameters of a given reserve
    /// @dev We inline assign each state to save gas instead of using Struct constructor
    /// @dev Potential flaw of this tokenomics:
    /// - Ability for the crown to change freely reserve parameters. (suggestion: immutable reserve/reserve parameter)
    /// @param _reserve the address of the asset to be used (ERC20 compliant)
    /// @param _mintingInterestRate The interest rate to be vested at mint
    /// @param _burningTaxRate The Burning tax rate that will go to sWagme holders
    /// @param _vestingPeriod The period where the interests will unlock
    /// @param _reserveOracle The oracle that is used for the exchange rate
    /// @param _disabled Controls the ability to be able to mint or not with the given asset
    function bless(
        address _reserve,
        uint128 _mintingInterestRate,
        uint128 _burningTaxRate,
        uint256 _vestingPeriod,
        address _reserveOracle,
        bool _disabled,
        bool _isReproveWhitelisted
    ) external onlyCrown {
        require(_reserveOracle != address(0), 'King: Invalid oracle');

        // Add or remove the reserve if needed from reserveReproveWhitelistAddresses

        Reserve storage reserve = reserves[_reserve];
        _updateReserveReproveWhitelistAddresses(reserve, _reserve, _isReproveWhitelisted);
        reserve.mintingInterestRate = _mintingInterestRate;
        reserve.burningTaxRate = _burningTaxRate;
        reserve.vestingPeriod = _vestingPeriod;
        reserve.reserveOracle = IReserveOracle(_reserveOracle);
        reserve.disabled = _disabled;
        reserve.isReproveWhitelisted = _isReproveWhitelisted;

        // !\ Careful of gas cost /!\
        if (!doesReserveExists(_reserve)) {
            reserveAddresses.push(_reserve);
        }

        emit RegisteredReserve(
            _reserve,
            reserveAddresses.length - 1,
            block.number,
            _mintingInterestRate,
            _burningTaxRate,
            _vestingPeriod,
            _reserveOracle,
            _disabled,
            _isReproveWhitelisted
        );
    }

    /// @notice Mint a given [[_amount]] of $WUSD using [[_reserve]] asset to an [[_account]]
    /// @dev Compute and send to the King the amount of [[_reserve]] in exchange of $WUSD.
    /// The $WUSD minted takes in consideration vestings
    /// @param _reserve The asset to be used (ERC20)
    /// @param _account The receiver of $WUSD
    /// @param _amount The amount of $WUSD minted
    /// @return totalMinted True amount of $WUSD minted
    function praise(
        address _reserve,
        address _account,
        uint256 _amount
    ) external reserveExists(_reserve) returns (uint256 totalMinted) {
        Reserve storage reserve = reserves[_reserve];
        totalMinted += _amount;

        uint256 toExchange = reserve.reserveOracle.getExchangeRate(_amount);

        IERC20(_reserve).transferFrom(msg.sender, address(this), toExchange);

        Vesting storage vesting = vestings[_account];
        // If the vesting period is unlocked, add it to the total to be minted
        if (block.number >= vesting.unlockPeriod) {
            totalMinted += vesting.amount;
            emit VestingRedeem(_account, vesting.amount);
        }
        // Reset the vesting params
        vesting.unlockPeriod = block.number + reserve.vestingPeriod;
        vesting.amount = _amount.mul(reserve.mintingInterestRate).div(10000);

        // TODO test this
        freeReserves[_reserve] += _amount.mul(reserve.burningTaxRate).div(10000);

        wusd.mint(_account, totalMinted);
        emit Praise(_reserve, _account, totalMinted);

        return totalMinted;
    }

    /// @notice Burn $WUSD in exchange of the desired reserve. A certain amount could be taxed and sent to sWagme
    /// @param _reserve The reserve to exchange with
    /// @param _amount The amount of $WUSD to reprove
    /// @return toExchange The amount of chosen reserve exchanged
    // TODO test isReproveWhitelisted require
    function reprove(address _reserve, uint256 _amount) external reserveExists(_reserve) returns (uint256 toExchange) {
        Reserve storage reserve = reserves[_reserve];
        require(reserve.isReproveWhitelisted, 'King: reserve not whitelisted for reproval');
        uint256 sWagmeTax = _amount.mul(sWagmeTaxRate).div(10000);
        toExchange = IReserveOracle(reserve.reserveOracle).getExchangeRate(_amount - sWagmeTax);

        // Send to WAGME
        wusd.burnFrom(msg.sender, _amount - sWagmeTax);
        wusd.transferFrom(msg.sender, sWagmeKingdom, sWagmeTax);

        // Send underlyings to sender
        IERC20(_reserve).transfer(msg.sender, toExchange);

        emit Reprove(_reserve, msg.sender, _amount);
    }

    /// @notice Redeem any ongoing vesting for a given account
    /// @dev Mint $WUSD and reset vesting terms
    /// @param _account The vesting account
    /// @return redeemed The amount of $WUSD redeemed
    function redeemVesting(address _account) external returns (uint256 redeemed) {
        Vesting storage vesting = vestings[_account];
        if (block.number >= vesting.unlockPeriod) {
            redeemed = vesting.amount;
            vesting.amount = 0;
            wusd.mint(_account, redeemed);
            emit VestingRedeem(_account, redeemed);
        }
    }

    /// @notice Useful for frontend. Get an estimate exchange of $WUSD vs desired reserve.
    /// takes in account any vested amount
    /// @param _reserve The asset to be used (ERC20)
    /// @param _account The receiver of $WUSD
    /// @param _amount The amount of $WUSD to mint
    /// @return toExchange Amount of reserve to exchange,
    /// @return amount True amount of $WUSD to be exchanged
    /// @return vested Any vesting created
    function getPraiseEstimates(
        address _reserve,
        address _account,
        uint256 _amount
    )
        external
        view
        reserveExists(_reserve)
        returns (
            uint256 toExchange,
            uint256 amount,
            uint256 vested
        )
    {
        Reserve storage reserve = reserves[_reserve];
        Vesting storage vesting = vestings[_account];

        toExchange = reserve.reserveOracle.getExchangeRate(_amount);
        // If there vesting period is unlocked, add it to the total minted
        if (block.number >= vesting.unlockPeriod) {
            _amount += vesting.amount;
        }
        vested = _amount.mul(reserve.mintingInterestRate).div(10000);
        amount = _amount;
    }

    /// @notice Check if a reserve was created
    /// @dev /!\ Careful of gas cost /!\
    /// @param _reserve The reserve to check
    /// @return exists A boolean of its existence
    function doesReserveExists(address _reserve) public view returns (bool exists) {
        for (uint256 i = 0; i < reserveAddresses.length; i++) {
            if (reserveAddresses[i] == _reserve) {
                exists = true;
                break;
            }
        }
    }

    /// @notice Withdraw [[_to]] a given [[_amount]] of [[_reserve]] and reset its freeReserves
    /// @dev Potential flaw of this tokenomics:
    /// - Ability to withdraw assets and break the burning mechanism.
    /// (suggestion: if reserve not immutable, compute a max amount withdrawable delta for a given reserve)
    /// @param _reserve The asset to be used (ERC20)
    /// @param _to The receiver
    /// @param _amount The amount to withdrawn
    // TODO test freeReserve
    function withdrawReserve(
        address _reserve,
        address _to,
        uint256 _amount
    ) external onlyCrown {
        require(address(reserves[_reserve].reserveOracle) != address(0), "King: reserve doesn't exists");
        IERC20(_reserve).transfer(_to, _amount);
        // Based on specs, reset behavior is wanted
        freeReserves[_reserve] = 0; // Reset freeReserve
        emit WithdrawReserve(_reserve, _to, _amount);
    }

    /// @notice Drain every reserve [[_to]] and reset all freeReserves
    /// @dev /!\ Careful of gas cost /!\
    /// @dev Potential flaw of this tokenomics:
    /// - Ability to withdraw assets and break the burning mechanism.
    /// (suggestion: if reserve not immutable, compute a max amount withdrawable delta for a given reserve)
    /// @param _to The receiver
    // TODO test freeReserve
    function withdrawAll(address _to) external onlyCrown {
        for (uint256 i = 0; i < reserveAddresses.length; i++) {
            IERC20 reserveERC20 = IERC20(reserveAddresses[i]);
            uint256 amount = reserveERC20.balanceOf(address(this));
            reserveERC20.transfer(_to, amount);
            freeReserves[reserveAddresses[i]] = 0; // Reset freeReserve
            emit WithdrawReserve(address(reserveERC20), _to, amount);
        }
    }

    /// @notice Withdraw a chosen amount of free reserve in the chosen reserve
    /// @param _reserve The asset to be used (ERC20)
    /// @param _to The receiver
    /// @param _amount The amount to withdrawn (in WUSD)
    /// @return assetWithdrawn The amount of asset withdrawn after the exchange rate
    function withdrawFreeReserve(
        address _reserve,
        address _to,
        uint256 _amount
    ) public onlyCrown returns (uint256 assetWithdrawn) {
        require(_amount <= freeReserves[_reserve], 'King: max amount exceeded');
        Reserve storage reserve = reserves[_reserve];
        require(address(reserve.reserveOracle) != address(0), "King: reserve doesn't exists");
        assetWithdrawn = reserve.reserveOracle.getExchangeRate(_amount);
        freeReserves[_reserve] -= _amount;
        IERC20(_reserve).transfer(_to, assetWithdrawn);
    }

    function withdrawAllFreeReserve(address _reserve, address _to) external onlyCrown returns (uint256 assetWithdrawn) {
        assetWithdrawn = withdrawFreeReserve(_reserve, _to, freeReserves[_reserve]);
    }

    /// @notice Update the sWagmeKingdom address
    /// @param _sWagmeKingdom The new address
    function updateSWagmeKingdom(address _sWagmeKingdom) external onlyCrown {
        sWagmeKingdom = _sWagmeKingdom;
    }

    /// @notice Update the sWagmeTaxRate state var
    /// @param _sWagmeTaxRate The new tax rate
    function updateSWagmeTaxRate(uint256 _sWagmeTaxRate) external onlyCrown {
        sWagmeTaxRate = _sWagmeTaxRate;
    }

    /// @notice Update the owner
    /// @param _newKing of the new owner
    function crownKing(address _newKing) external onlyCrown {
        crown = _newKing;
    }

    /// @notice Transfer an ERC20 to the king
    /// @param _erc20 The address of the token to transfer
    /// @param _to The address of the receiver
    /// @param _amount The amount to transfer
    function salvage(
        address _erc20,
        address _to,
        uint256 _amount
    ) external onlyCrown {
        IERC20(_erc20).transfer(_to, _amount);
    }

    /// @notice Withdraw the native currency to the king
    /// @param _to The address of the receiver
    /// @param _amount The amount to be withdrawn
    function withdrawNative(address payable _to, uint256 _amount) external onlyCrown {
        _to.transfer(_amount);
    }

    /// @dev Updated [[reserveReproveWhitelistAddresses]] when a reserve is updated or appended.
    /// Changes occurs only if needed. It is designed to be called only at the begining of a blessing [[bless()]]
    /// @param _reserve The reserve being utilized
    /// @param _reserveAddress The address of the reserve
    /// @param _isReproveWhitelisted The most updated version of reserve.isReproveWhitelisted
    function _updateReserveReproveWhitelistAddresses(
        Reserve memory _reserve,
        address _reserveAddress,
        bool _isReproveWhitelisted
    ) internal {
        // Check if it exists
        if (address(_reserve.reserveOracle) != address(0)) {
            // We'll act only if there was changes
            if (_reserve.isReproveWhitelisted != _isReproveWhitelisted) {
                // We'll add or remove it from reserveReproveWhitelistAddresses based on the previous param
                if (_isReproveWhitelisted) {
                    // Added to the whitelist
                    reserveReproveWhitelistAddresses.push(_reserveAddress);
                    emit UpdateReserveReproveWhitelistAddresses(_reserveAddress, true, false);
                } else {
                    // Remove it from the whitelist
                    // /!\ Gas cost /!\
                    for (uint256 i = 0; i < reserveReproveWhitelistAddresses.length; i++) {
                        if (reserveReproveWhitelistAddresses[i] == _reserveAddress) {
                            // Get the last element in the removed element
                            reserveReproveWhitelistAddresses[i] = reserveReproveWhitelistAddresses[
                                reserveReproveWhitelistAddresses.length - 1
                            ];
                            reserveReproveWhitelistAddresses.pop();
                            emit UpdateReserveReproveWhitelistAddresses(_reserveAddress, false, false);
                        }
                    }
                }
            }
        } else {
            // If the reserve is new, we'll add it to the whitelist only if it's whitelisted
            if (_isReproveWhitelisted) {
                reserveReproveWhitelistAddresses.push(_reserveAddress);
                emit UpdateReserveReproveWhitelistAddresses(_reserveAddress, true, true);
            }
        }
    }
}
