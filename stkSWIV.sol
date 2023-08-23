// SPDX-License-Identifier: UNLICENSED
pragma solidity >= 0.8.4;

import './ERC/SolmateERC20.sol';
import './Utils/SafeTransferLib.sol';
import './Interfaces/IVault.sol';

contract stkSWIV is ERC20 {
    // The Swivel Multisig (or should be)
    address public admin;
    // The Swivel Token
    ERC20 immutable public SWIV;
    // The Swivel/ETH balancer LP token
    ERC20 immutable public balancerLPT;
    // The Static Balancer Vault
    IVault immutable public balancerVault;
    // The Balancer Pool ID
    bytes32 public balancerPoolID;
    // The withdrawal cooldown length
    uint256 public cooldownLength = 2 weeks;
    // Mapping of user address -> unix timestamp for cooldown
    mapping (address => uint256) cooldownTime;
    // Mapping of user address -> amount of balancerLPT assets to be withdrawn
    mapping (address => uint256) cooldownAmount;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    error Exception(uint8, uint256, uint256, address, address);

    constructor (ERC20 s, IVault v, ERC20 b, bytes32 p) ERC20("Staked SWIV/ETH", "stkSWIV", s.decimals() + 18) {
        SWIV = s;
        balancerVault = v;
        balancerLPT = b;
        balancerPoolID = p;
        admin = msg.sender;
        SafeTransferLib.approve(SWIV, address(balancerLPT), type(uint256).max);
    }

    function totalAssets() public view returns (uint256 assets) {
        return (balancerLPT.balanceOf(address(this)));
    }

    // The number of SWIV/ETH balancer shares owned / the stkSWIV total supply
    // Conversion of 1 stkSWIV share to an amount of SWIV/ETH balancer shares (scaled to 1e18) (starts at 1:1e18)
    // Buffered by 1e18 to avoid 4626 inflation attacks -- https://ethereum-magicians.org/t/address-eip-4626-inflation-attacks-with-virtual-shares-and-assets/12677
    // @returns: the exchange rate
    function exchangeRateCurrent() public view returns (uint256) {
        return (this.totalSupply() + 1e18 / totalAssets() + 1);
    }

    // Conversion of amount of SWIV/ETH balancer assets to stkSWIV shares
    // @param: assets - amount of SWIV/ETH balancer pool tokens
    // @returns: the amount of stkSWIV shares
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        return (assets) * exchangeRateCurrent();
    }

    // Conversion of amount of stkSWIV shares to SWIV/ETH balancer assets
    // @param: shares - amount of stkSWIV shares
    // @returns: the amount of SWIV/ETH balancer pool tokens
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        return (shares / exchangeRateCurrent());
    }

    // Maximum amount a given receiver can mint
    // @param: receiver - address of the receiver
    // @returns: the maximum amount of stkSWIV shares
    function maxMint(address receiver) public pure returns (uint256 maxShares) {
        return type(uint256).max;
    }

    // Maximum amount a given owner can redeem
    // @param: owner - address of the owner
    // @returns: the maximum amount of stkSWIV shares
    function maxRedeem(address owner) public view returns (uint256 maxShares) {
        return (this.balanceOf(owner));
    }

    // Maximum amount a given owner can withdraw
    // @param: owner - address of the owner
    // @returns: the maximum amount of balancerLPT assets
    function maxWithdraw(address owner) public view returns (uint256 maxAssets) {
        return (convertToAssets(this.balanceOf(owner)));
    }

    // Maximum amount a given receiver can deposit
    // @param: receiver - address of the receiver
    // @returns: the maximum amount of balancerLPT assets
    function maxDeposit(address receiver) public pure returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    // Queues `amount` of balancerLPT assets to be withdrawn after the cooldown period
    // @param: amount - amount of balancerLPT assets to be withdrawn
    // @returns: the total amount of balancerLPT assets to be withdrawn
    function cooldown(uint256 amount) public returns (uint256) {

        // Require the total amount to be < balanceOf
        if (cooldownAmount[msg.sender] + amount > balanceOf[msg.sender]) {
            revert Exception(3, cooldownAmount[msg.sender] + amount, balanceOf[msg.sender], msg.sender, address(0));
        }
        // Reset cooldown time
        cooldownTime[msg.sender] = block.timestamp + cooldownLength;
        // Add the amount;
        cooldownAmount[msg.sender] = cooldownAmount[msg.sender] + amount;

        return(cooldownAmount[msg.sender] + amount);
    }

    // Mints `shares` to `receiver` and transfers `assets` of balancerLPT tokens from `msg.sender`
    // @param: shares - amount of stkSWIV shares to mint
    // @param: receiver - address of the receiver
    // @returns: the amount of balancerLPT tokens deposited
    function mint(uint256 shares, address receiver) public payable returns (uint256) {
        // Convert shares to assets
        uint256 assets = convertToAssets(shares);
        // Transfer assets of balancer LP tokens from sender to this contract
        SafeTransferLib.transferFrom(balancerLPT, msg.sender, address(this), assets);
        // Mint shares to receiver
        _mint(receiver, shares);
        // Emit deposit event
        emit Deposit(msg.sender, receiver, assets, shares);

        return (assets);
    }

    // Redeems `shares` from `owner` and transfers `assets` of balancerLPT tokens to `receiver`
    // @param: shares - amount of stkSWIV shares to redeem
    // @param: receiver - address of the receiver
    // @param: owner - address of the owner
    // @returns: the amount of balancerLPT tokens withdrawn
    function redeem(uint256 shares, address receiver, address owner) public returns (uint256) {
        // Convert shares to assets
        uint256 assets = convertToAssets(shares);
        // Get the cooldown time
        uint256 cTime = cooldownTime[msg.sender];
        // If the sender is not the owner check allowances
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            // If the allowance is not max, subtract the shares from the allowance, reverts on underflow if not enough allowance
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
        // If the cooldown time is in the future or 0, revert
        if (cTime > block.timestamp || cTime == 0) {
            revert Exception(0, cTime, block.timestamp, address(0), address(0));
        }
        // If the cooldown amount is greater than the assets, revert
        uint256 cAmount = cooldownAmount[msg.sender];
        if (cAmount > assets) {
            revert Exception(1, cAmount, shares, address(0), address(0));
        }
        // If the shares are greater than the balance of the owner, revert
        if (shares > this.balanceOf(owner)) {
            revert Exception(2, shares, this.balanceOf(owner), address(0), address(0));
        }
        // Transfer the balancer LP tokens to the receiver
        SafeTransferLib.transfer(balancerLPT, receiver, assets);
        // Burn the shares
        _burn(msg.sender, shares);
        // Reset the cooldown time
        cooldownTime[msg.sender] = 0;
        // Reset the cooldown amount
        cooldownAmount[msg.sender] = 0;
        // Emit withdraw event
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return (assets);
    }

    // Deposits `assets` of balancerLPT tokens from `msg.sender` and mints `shares` to `receiver`
    // @param: assets - amount of balancerLPT tokens to deposit
    // @param: receiver - address of the receiver
    // @returns: the amount of stkSWIV shares minted
    function deposit(uint256 assets, address receiver) public returns (uint256) {
        // Convert assets to shares          
        uint256 shares = convertToShares(assets);
        // Transfer assets of balancer LP tokens from sender to this contract
        SafeTransferLib.transferFrom(SWIV, msg.sender, address(this), assets);        
        // Mint shares to receiver
        _mint(receiver, shares);
        // Emit deposit event
        emit Deposit(msg.sender, receiver, assets, shares);

        return (shares);
    }

    // Withdraws `assets` of balancerLPT tokens to `receiver` and burns `shares` from `owner`
    // @param: assets - amount of balancerLPT tokens to withdraw
    // @param: receiver - address of the receiver
    // @param: owner - address of the owner
    // @returns: the amount of stkSWIV shares withdrawn
    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256) {
        // Convert assets to shares
        uint256 shares = convertToShares(assets);
        // Get the cooldown time
        uint256 cTime = cooldownTime[msg.sender];
        // If the sender is not the owner check allowances
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            // If the allowance is not max, subtract the shares from the allowance, reverts on underflow if not enough allowance
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
        // If the cooldown time is in the future or 0, revert
        if (cTime > block.timestamp || cTime == 0) {
            revert Exception(0, cTime, block.timestamp, address(0), address(0));
        }
        // If the cooldown amount is greater than the assets, revert
        uint256 cAmount = cooldownAmount[msg.sender];
        if (cAmount > assets) {
            revert Exception(1, cAmount, shares, address(0), address(0));
        }
        // If the shares are greater than the balance of the owner, revert
        if (shares > this.balanceOf(owner)) {
            revert Exception(2, shares, this.balanceOf(owner), address(0), address(0));
        }
        // Transfer the balancer LP tokens to the receiver
        SafeTransferLib.transfer(balancerLPT, receiver, assets);
        // Burn the shares   
        _burn(msg.sender, shares);
        // Reset the cooldown time
        cooldownTime[msg.sender] = 0;
        // Reset the cooldown amount
        cooldownAmount[msg.sender] = 0;
        // Emit withdraw event
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return (shares);
    }

    //////////////////// ZAP METHODS ////////////////////

    // Transfers `assets` of SWIV tokens from `msg.sender` while receiving `msg.value` of ETH
    // Then joins the balancer pool with the SWIV and ETH before minting `shares` to `receiver`
    // @param: shares - amount of stkSWIV shares to mint
    // @param: receiver - address of the receiver
    // @returns: the amount of SWIV tokens deposited
    function mintZap(uint256 shares, address receiver) public payable returns (uint256) {
        // Convert shares to assets
        uint256 assets = convertToAssets(shares);
        // Transfer assets of SWIV tokens from sender to this contract
        SafeTransferLib.transferFrom(SWIV, msg.sender, address(this), assets);

        // Instantiate balancer request struct using SWIV and ETH alongside the amounts sent
        IAsset[] memory assetData;
        assetData[0] = IAsset(address(SWIV));
        assetData[1] = IAsset(address(0));

        uint256[] memory amountData;
        amountData[0] = assets;
        amountData[1] = msg.value;

        IVault.JoinPoolRequest memory requestData = IVault.JoinPoolRequest({
            assets: assetData,
            maxAmountsIn: amountData,
            userData: new bytes(0),
            fromInternalBalance: false
        });
        // Join the balancer pool using the request struct
        IVault(balancerVault).joinPool(balancerPoolID, address(this), address(this), requestData);
        // Mint shares to receiver
        _mint(receiver, shares);
        // Emit deposit event
        emit Deposit(msg.sender, receiver, assets, shares);

        return (assets);
    }

    // Exits the balancer pool and transfers `assets` of SWIV tokens and the current balance of ETH to `receiver`
    // Then burns `shares` from `owner`
    // @param: shares - amount of stkSWIV shares to redeem
    // @param: receiver - address of the receiver
    // @param: owner - address of the owner
    // @returns: the amount of SWIV tokens withdrawn
    function redeemZap(uint256 shares, address payable receiver, address owner) public returns (uint256) {
        // Convert shares to assets
        uint256 assets = convertToAssets(shares);
        // Get the cooldown time
        uint256 cTime = cooldownTime[msg.sender];
        // If the sender is not the owner check allowances
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            // If the allowance is not max, subtract the shares from the allowance, reverts on underflow if not enough allowance
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
        // If the cooldown time is in the future or 0, revert
        if (cTime > block.timestamp || cTime == 0) {
            revert Exception(0, cTime, block.timestamp, address(0), address(0));
        }
        // If the cooldown amount is greater than the assets, revert
        uint256 cAmount = cooldownAmount[msg.sender];
        if (cAmount > assets) {
            revert Exception(1, cAmount, shares, address(0), address(0));
        }
        // If the shares are greater than the balance of the owner, revert
        if (shares > this.balanceOf(owner)) {
            revert Exception(2, shares, this.balanceOf(owner), address(0), address(0));
        }
        // Instantiate balancer request struct using SWIV and ETH alongside the asset amount and 0 ETH
        IAsset[] memory assetData;
        assetData[0] = IAsset(address(SWIV));
        assetData[1] = IAsset(address(0));

        uint256[] memory amountData;
        amountData[0] = assets;
        amountData[1] = 0;

        IVault.ExitPoolRequest memory requestData = IVault.ExitPoolRequest({
            assets: assetData,
            minAmountsOut: amountData,
            userData: new bytes(0),
            toInternalBalance: false
        });
        // Exit the balancer pool using the request struct
        IVault(balancerVault).exitPool(balancerPoolID, payable(address(this)), payable(address(this)), requestData);
        // Transfer the SWIV tokens to the receiver
        SafeTransferLib.transfer(SWIV, receiver, SWIV.balanceOf(address(this)));
        // Transfer the ETH to the receiver
        receiver.transfer(address(this).balance);
        // Burn the shares
        _burn(msg.sender, shares);
        // Reset the cooldown time
        cooldownTime[msg.sender] = 0;
        // Reset the cooldown amount
        cooldownAmount[msg.sender] = 0;
        // Emit withdraw event
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return (assets);
    }

    // Transfers `assets` of SWIV tokens from `msg.sender` while receiving `msg.value` of ETH
    // Then joins the balancer pool with the SWIV and ETH before minting `shares` to `receiver`
    // @param: assets - amount of SWIV tokens to deposit
    // @param: receiver - address of the receiver
    // @returns: the amount of stkSWIV shares minted
    function depositZap(uint256 assets, address receiver) public payable returns (uint256) {

        // Convert assets to shares
        uint256 shares = convertToShares(assets);
        // Transfer assets of SWIV tokens from sender to this contract
        SafeTransferLib.transferFrom(SWIV, msg.sender, address(this), assets);    
        // Instantiate balancer request struct using SWIV and ETH alongside the amounts sent
        IAsset[] memory assetData;
        assetData[0] = IAsset(address(SWIV));
        assetData[1] = IAsset(address(0));

        uint256[] memory amountData;
        amountData[0] = assets;
        amountData[1] = msg.value;

        IVault.JoinPoolRequest memory requestData = IVault.JoinPoolRequest({
            assets: assetData,
            maxAmountsIn: amountData,
            userData: new bytes(0),
            fromInternalBalance: false
        });
        // Join the balancer pool using the request struct
        IVault(balancerVault).joinPool(balancerPoolID, address(this), address(this), requestData);
        // Mint shares to receiver
        _mint(receiver, shares);
        // Emit deposit event
        emit Deposit(msg.sender, receiver, assets, shares);

        return (shares);
    }

    // Exits the balancer pool and transfers `assets` of SWIV tokens and the current balance of ETH to `receiver`
    // Then burns `shares` from `owner`
    // @param: assets - amount of SWIV tokens to withdraw
    // @param: receiver - address of the receiver
    // @param: owner - address of the owner
    // @returns: the amount of stkSWIV shares burnt
    function withdrawZap(uint256 assets, address payable receiver, address owner) public returns (uint256) {
        // Convert assets to shares
        uint256 shares = convertToShares(assets);
        // Get the cooldown time
        uint256 cTime = cooldownTime[msg.sender];
        // If the sender is not the owner check allowances
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            // If the allowance is not max, subtract the shares from the allowance, reverts on underflow if not enough allowance
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
        // If the cooldown time is in the future or 0, revert
        if (cTime > block.timestamp || cTime == 0) {
            revert Exception(0, cTime, block.timestamp, address(0), address(0));
        }
        // If the cooldown amount is greater than the assets, revert
        uint256 cAmount = cooldownAmount[msg.sender];
        if (cAmount > assets) {
            revert Exception(1, cAmount, shares, address(0), address(0));
        }
        // If the shares are greater than the balance of the owner, revert
        if (shares > this.balanceOf(owner)) {
            revert Exception(2, shares, this.balanceOf(owner), address(0), address(0));
        }
        // Instantiate balancer request struct using SWIV and ETH alongside the asset amount and 0 ETH
        IAsset[] memory assetData;
        assetData[0] = IAsset(address(SWIV));
        assetData[1] = IAsset(address(0));

        uint256[] memory amountData;
        amountData[0] = assets;
        amountData[1] = 0;

        IVault.ExitPoolRequest memory requestData = IVault.ExitPoolRequest({
            assets: assetData,
            minAmountsOut: amountData,
            userData: new bytes(0),
            toInternalBalance: false
        });
        // Exit the balancer pool using the request struct
        IVault(balancerVault).exitPool(balancerPoolID, payable(address(this)), payable(address(this)), requestData);
        // Transfer the SWIV tokens to the receiver
        SafeTransferLib.transfer(SWIV, receiver, SWIV.balanceOf(address(this)));
        // Transfer the ETH to the receiver
        receiver.transfer(address(this).balance);
        // Burn the shares
        _burn(msg.sender, shares);
        // Reset the cooldown time
        cooldownTime[msg.sender] = 0;
        // Reset the cooldown amount
        cooldownAmount[msg.sender] = 0;
        // Emit withdraw event
        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        return (shares);
    }

    //////////////////// ADMIN FUNCTIONS ////////////////////

    // Method to redeem and withdraw BAL incentives or other stuck tokens / those needing recovery
    // @param: token - address of the token to withdraw
    // @param: receiver - address of the receiver
    // @returns: the amount of tokens withdrawn
    function BALWithdraw(address token, address payable receiver) Authorized(admin) public returns (uint256) {
        if (token == address(0)) {
            receiver.transfer(address(this).balance);
            return (address(this).balance);
        }
        else {
            // Get the balance of the token
            uint256 balance = IERC20(token).balanceOf(address(this));
            // Transfer the token to the receiver
            SafeTransferLib.transfer(ERC20(token), receiver, balance);
            return (balance);
        }
    }

    // Sets a new admin address
    // @param: _admin - address of the new admin
    function setAdmin(address _admin) Authorized(admin) public {
        admin = _admin;
    }

    // Authorized modifier
    modifier Authorized(address) {
        require(msg.sender == admin || msg.sender == address(this), "Not authorized");
        _;
    }
}