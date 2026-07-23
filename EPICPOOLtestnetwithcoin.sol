// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title EpicCoin (`EPC`)
 * @dev ERC20 Token contract enforcing a strict 500 Million hard cap with 20% (100M) unminted reward reserve.
 */
contract EpicCoin is ERC20 {
    address public immutable lotteryContract;
    
    // Strict 500 Million Hard Cap (500,000,000 * 10^18)
    uint256 public constant MAX_SUPPLY = 500_000_000 * 10**18;

    constructor(
        address _lotteryContract, 
        address ownerAddress,
        address teamAddress
    ) ERC20("Epic Coin", "EPC") {
        lotteryContract = _lotteryContract;
        
        // 1. Initial Mint to Owner: 350,000,000 EPC (70% total: 50% Liquidity + 20% Owner)
        _mint(ownerAddress, 350_000_000 * 10**18);

        // 2. Initial Mint to Team: 50,000,000 EPC (10% Team & Salary)
        if (teamAddress != address(0)) {
            _mint(teamAddress, 50_000_000 * 10**18);
        } else {
            _mint(ownerAddress, 50_000_000 * 10**18); // Defaults to owner if no team address is provided
        }

        // Remaining 20% (100,000,000 EPC) stays unminted in reserve for Lottery Winners!
    }

    /// @notice Allows only the connected lottery contract to mint winner reward coins up to the 500M cap
    function mint(address to, uint256 amount) external {
        require(msg.sender == lotteryContract, "Only the Lottery contract can mint coins.");
        require(totalSupply() + amount <= MAX_SUPPLY, "Cannot mint beyond 500 Million cap!");
        _mint(to, amount);
    }
}

/**
 * @title AdvancedLotteryNFT
 * @notice Fixed supply of 10 NFTs + Integrated 500M EPC Coin Rewards (100k EPC per winner).
 */
contract AdvancedLotteryNFT is ERC721, VRFConsumerBaseV2Plus {
    using Strings for uint256;

    // --- ERC20 Custom Coin Config ---
    EpicCoin public immutable epicCoin;
    uint256 public constant WINNER_COIN_REWARD = 100_000 * 10**18; // 100,000 EPC per winner

    // --- Chainlink VRF Config ---
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public callbackGasLimit = 500000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;
    bool public payWithNativeEth = true; 

    enum RequestType { PRIMARY, SECONDARY }
    mapping(uint256 => RequestType) public requestTypes;

    // --- Strict 10-NFT Collection Supply Limits ---
    uint256 public constant TICKET_PRICE = 1 ether; 
    uint256 public constant MAX_GLOBAL_SUPPLY = 10; 
    uint256 public totalMintedSupply;
    address[10] public primaryMinters;
    bool public primaryDrawingInProgress;

    // --- Secondary Marketplace Logic ---
    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }
    
    mapping(uint256 => Listing) public marketplaceListings;
    
    uint256 public secondaryTransactionCount;
    uint256 public secondaryFeesAccumulated;
    address[10] public secondaryBuyers;
    bool public secondaryDrawingInProgress;

    // --- Events ---
    event TicketPurchased(address indexed buyer, uint256 indexed tokenId);
    event PrimaryDrawTriggered(uint256 requestId);
    event PrimaryWinnerPaid(address indexed winner, uint256 ethAmount, uint256 coinAmount, address indexed owner, uint256 ownerEthAmount);
    
    event NFTListed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event SecondarySaleExecuted(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 feeDeducted);
    event SecondaryDrawTriggered(uint256 requestId);
    event SecondaryWinnerPaid(address indexed winner, uint256 ethAmount, uint256 coinAmount, address indexed owner, uint256 ownerEthAmount);

    constructor(
        uint256 subscriptionId,
        bytes32 keyHash,
        address vrfCoordinator,
        address teamWallet
    ) 
        ERC721("EpicPoolLottery", "EPL") 
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        s_subscriptionId = subscriptionId;
        s_keyHash = keyHash;

        // Deploys EpicCoin and executes initial distribution:
        // 350M EPC to Owner (50% LP + 20% Owner), 50M EPC to Team (10%), 100M EPC reserved for Winners (20%).
        epicCoin = new EpicCoin(address(this), msg.sender, teamWallet);
    }

    // --- 1. Automated On-Chain Metadata ---
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        bytes memory dataURI = abi.encodePacked(
            '{',
                '"name": "EPIC NUMBER #', tokenId.toString(), '",',
                '"description": "Exclusive Epic Pool Lottery Ticket NFT",',
                '"attributes": [{"trait_type": "Edition", "value": ', tokenId.toString(), '}]',
            '}'
        );

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(dataURI)
            )
        );
    }

    // --- 2. Primary Mint Function ---
    function buyTicket() external payable {
        require(totalMintedSupply < MAX_GLOBAL_SUPPLY, "All 10 NFTs have been minted! Primary market is closed forever.");
        require(!primaryDrawingInProgress, "Primary lottery drawing in progress, please wait.");
        require(msg.value == TICKET_PRICE, "Incorrect payment: Must send exactly 1 ETH.");

        primaryMinters[totalMintedSupply] = msg.sender;
        totalMintedSupply++;

        uint256 newTokenId = totalMintedSupply;
        _safeMint(msg.sender, newTokenId);

        emit TicketPurchased(msg.sender, newTokenId);

        if (totalMintedSupply == MAX_GLOBAL_SUPPLY) {
            primaryDrawingInProgress = true;
            triggerVRFDraw(RequestType.PRIMARY);
        }
    }

    // --- 3. Secondary Marketplace Functions ---
    function listNFT(uint256 tokenId, uint256 price) external {
        require(ownerOf(tokenId) == msg.sender, "You do not own this NFT.");
        require(price > 0, "Price must be greater than zero.");
        
        marketplaceListings[tokenId] = Listing({
            seller: msg.sender,
            price: price,
            active: true
        });

        emit NFTListed(tokenId, msg.sender, price);
    }

    function buySecondaryNFT(uint256 tokenId) external payable {
        Listing memory listing = marketplaceListings[tokenId];
        require(listing.active, "NFT is not actively listed for sale.");
        require(msg.value == listing.price, "Please submit the exact sale price.");
        require(!secondaryDrawingInProgress, "Secondary drawing active. Marketplace briefly locked.");

        marketplaceListings[tokenId].active = false;

        uint256 fee;
        if (msg.value > 1 ether) {
            fee = (msg.value * 10) / 100; // 10% fee if price > 1 ETH
        } else {
            fee = 0.1 ether; // Flat 0.1 ETH fee if price <= 1 ETH
        }

        require(msg.value > fee, "Sale price is lower than the required execution fee.");
        uint256 sellerProceeds = msg.value - fee;

        secondaryFeesAccumulated += fee;
        secondaryBuyers[secondaryTransactionCount] = msg.sender;
        secondaryTransactionCount++;

        _transfer(listing.seller, msg.sender, tokenId);

        (bool successSeller, ) = payable(listing.seller).call{value: sellerProceeds}("");
        require(successSeller, "Transfer to seller failed.");

        emit SecondarySaleExecuted(tokenId, listing.seller, msg.sender, listing.price, fee);

        if (secondaryTransactionCount == MAX_GLOBAL_SUPPLY) {
            secondaryDrawingInProgress = true;
            triggerVRFDraw(RequestType.SECONDARY);
        }
    }

    // --- 4. Internal Chainlink VRF Request Trigger ---
    function triggerVRFDraw(RequestType rType) internal {
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: payWithNativeEth})
                )
            })
        );

        requestTypes[requestId] = rType;
        
        if (rType == RequestType.PRIMARY) {
            emit PrimaryDrawTriggered(requestId);
        } else {
            emit SecondaryDrawTriggered(requestId);
        }
    }

    // --- 5. Chainlink Oracle Callback & Winner Payouts ---
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        RequestType rType = requestTypes[requestId];
        uint256 winningIndex = randomWords[0] % MAX_GLOBAL_SUPPLY;

        if (rType == RequestType.PRIMARY) {
            address primaryWinner = primaryMinters[winningIndex];
            
            uint256 winnerPayout = 5 ether;
            uint256 ownerPayout = 5 ether;

            primaryDrawingInProgress = false; 

            // 🎁 MINTS 100,000 EPIC COINS TO THE PRIMARY WINNER
            epicCoin.mint(primaryWinner, WINNER_COIN_REWARD);

            (bool successWinner, ) = payable(primaryWinner).call{value: winnerPayout}("");
            require(successWinner, "Primary payout to winner failed.");

            (bool successOwner, ) = payable(owner()).call{value: ownerPayout}("");
            require(successOwner, "Primary payout to owner failed.");

            emit PrimaryWinnerPaid(primaryWinner, winnerPayout, WINNER_COIN_REWARD, owner(), ownerPayout);

        } else if (rType == RequestType.SECONDARY) {
            address secondaryWinner = secondaryBuyers[winningIndex];
            
            uint256 totalPool = secondaryFeesAccumulated;
            uint256 winnerPayout = (totalPool * 75) / 100;
            uint256 ownerPayout = totalPool - winnerPayout;

            secondaryTransactionCount = 0;
            secondaryFeesAccumulated = 0;
            secondaryDrawingInProgress = false;

            // 🎁 MINTS 100,000 EPIC COINS TO THE SECONDARY WINNER
            epicCoin.mint(secondaryWinner, WINNER_COIN_REWARD);

            (bool successSecWinner, ) = payable(secondaryWinner).call{value: winnerPayout}("");
            require(successSecWinner, "Secondary payout to winner failed.");

            (bool successSecOwner, ) = payable(owner()).call{value: ownerPayout}("");
            require(successSecOwner, "Secondary payout to owner failed.");

            emit SecondaryWinnerPaid(secondaryWinner, winnerPayout, WINNER_COIN_REWARD, owner(), ownerPayout);
        }
    }

    // --- Admin Configuration Switches ---
    function setPaymentMethod(bool _payWithNative) external onlyOwner {
        payWithNativeEth = _payWithNative;
    }

    function updateVRFConfig(uint32 _gasLimit, uint16 _confirmations) external onlyOwner {
        callbackGasLimit = _gasLimit;
        requestConfirmations = _confirmations;
    }
}
