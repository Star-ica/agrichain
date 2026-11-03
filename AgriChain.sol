// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AgriChain
 * @notice Decentralized crop supply chain & traceability platform on Botchain
 * @dev Farmers register produce lots; buyers trace full provenance on-chain
 */
contract AgriChain {

    // ─── Enums ────────────────────────────────────────────────────────────────
    enum LotStatus { Registered, Harvested, InTransit, AtWarehouse, Sold }

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct Farmer {
        address wallet;
        string  name;
        string  location;
        uint256 registeredAt;
        bool    verified;
        uint256 totalLotsCreated;
    }

    struct ProduceLot {
        uint256 id;
        address farmer;
        string  cropType;
        string  variety;
        uint256 weightKg;
        uint256 harvestDate;
        string  farmLocation;
        LotStatus status;
        uint256 pricePerKgWei;
        address currentOwner;
        uint256 createdAt;
    }

    struct Checkpoint {
        address handler;
        string  location;
        string  action;       // e.g. "Harvested", "Quality Check Passed", "Loaded"
        uint256 timestamp;
        string  notes;
    }

    // ─── State ────────────────────────────────────────────────────────────────
    address public owner;
    uint256 public lotCounter;
    uint256 public platformFeeBps = 100; // 1%

    mapping(address => Farmer)          public farmers;
    mapping(uint256 => ProduceLot)      public lots;
    mapping(uint256 => Checkpoint[])    public lotCheckpoints;
    mapping(address => bool)            public verifiers;   // trusted verifiers
    mapping(address => uint256[])       public farmerLots;

    // ─── Events ───────────────────────────────────────────────────────────────
    event FarmerRegistered(address indexed farmer, string name, string location);
    event FarmerVerified(address indexed farmer, address indexed verifier);
    event LotCreated(uint256 indexed lotId, address indexed farmer, string cropType, uint256 weightKg);
    event CheckpointAdded(uint256 indexed lotId, address indexed handler, string action, uint256 timestamp);
    event LotStatusUpdated(uint256 indexed lotId, LotStatus newStatus);
    event LotPurchased(uint256 indexed lotId, address indexed buyer, uint256 pricePaid);
    event VerifierAdded(address indexed verifier);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    modifier onlyVerifier() { require(verifiers[msg.sender] || msg.sender == owner, "Not verifier"); _; }
    modifier onlyFarmer(address _farmer) { require(msg.sender == _farmer, "Not farmer"); _; }
    modifier lotExists(uint256 _lotId) { require(_lotId > 0 && _lotId <= lotCounter, "Lot not found"); _; }

    constructor() { owner = msg.sender; verifiers[msg.sender] = true; }

    // ─── Farmer Management ───────────────────────────────────────────────────
    function registerFarmer(string calldata _name, string calldata _location) external {
        require(bytes(farmers[msg.sender].name).length == 0, "Already registered");
        farmers[msg.sender] = Farmer({
            wallet:          msg.sender,
            name:            _name,
            location:        _location,
            registeredAt:    block.timestamp,
            verified:        false,
            totalLotsCreated: 0
        });
        emit FarmerRegistered(msg.sender, _name, _location);
    }

    function verifyFarmer(address _farmer) external onlyVerifier {
        require(bytes(farmers[_farmer].name).length > 0, "Farmer not found");
        farmers[_farmer].verified = true;
        emit FarmerVerified(_farmer, msg.sender);
    }

    function addVerifier(address _verifier) external onlyOwner {
        verifiers[_verifier] = true;
        emit VerifierAdded(_verifier);
    }

    // ─── Lot Management ──────────────────────────────────────────────────────
    function createLot(
        string calldata _cropType,
        string calldata _variety,
        uint256 _weightKg,
        uint256 _harvestDate,
        string calldata _farmLocation,
        uint256 _pricePerKgWei
    ) external returns (uint256) {
        require(farmers[msg.sender].verified, "Farmer not verified");
        require(_weightKg > 0, "Invalid weight");

        lotCounter++;
        lots[lotCounter] = ProduceLot({
            id:            lotCounter,
            farmer:        msg.sender,
            cropType:      _cropType,
            variety:       _variety,
            weightKg:      _weightKg,
            harvestDate:   _harvestDate,
            farmLocation:  _farmLocation,
            status:        LotStatus.Registered,
            pricePerKgWei: _pricePerKgWei,
            currentOwner:  msg.sender,
            createdAt:     block.timestamp
        });

        farmers[msg.sender].totalLotsCreated++;
        farmerLots[msg.sender].push(lotCounter);

        // Auto-add creation checkpoint
        lotCheckpoints[lotCounter].push(Checkpoint({
            handler:   msg.sender,
            location:  _farmLocation,
            action:    "Lot Registered",
            timestamp: block.timestamp,
            notes:     "Initial registration on AgriChain"
        }));

        emit LotCreated(lotCounter, msg.sender, _cropType, _weightKg);
        return lotCounter;
    }

    function addCheckpoint(
        uint256 _lotId,
        string calldata _location,
        string calldata _action,
        string calldata _notes
    ) external lotExists(_lotId) {
        ProduceLot storage lot = lots[_lotId];
        require(
            msg.sender == lot.farmer || msg.sender == lot.currentOwner || verifiers[msg.sender],
            "Unauthorized"
        );

        lotCheckpoints[_lotId].push(Checkpoint({
            handler:   msg.sender,
            location:  _location,
            action:    _action,
            timestamp: block.timestamp,
            notes:     _notes
        }));

        emit CheckpointAdded(_lotId, msg.sender, _action, block.timestamp);
    }

    function updateLotStatus(uint256 _lotId, LotStatus _status) external lotExists(_lotId) {
        ProduceLot storage lot = lots[_lotId];
        require(
            msg.sender == lot.farmer || msg.sender == lot.currentOwner || verifiers[msg.sender],
            "Unauthorized"
        );
        lot.status = _status;
        emit LotStatusUpdated(_lotId, _status);
    }

    function purchaseLot(uint256 _lotId) external payable lotExists(_lotId) {
        ProduceLot storage lot = lots[_lotId];
        require(lot.status != LotStatus.Sold, "Already sold");

        uint256 totalPrice = lot.pricePerKgWei * lot.weightKg;
        require(msg.value >= totalPrice, "Insufficient payment");

        uint256 fee = (totalPrice * platformFeeBps) / 10000;
        uint256 farmerAmount = totalPrice - fee;

        address previousOwner = lot.currentOwner;
        lot.currentOwner = msg.sender;
        lot.status = LotStatus.Sold;

        // Transfer payment
        (bool sent,) = payable(previousOwner).call{value: farmerAmount}("");
        require(sent, "Payment failed");
        if (fee > 0) {
            (bool feeSent,) = payable(owner).call{value: fee}("");
            require(feeSent, "Fee transfer failed");
        }

        // Refund excess
        if (msg.value > totalPrice) {
            (bool refund,) = payable(msg.sender).call{value: msg.value - totalPrice}("");
            require(refund, "Refund failed");
        }

        // Add sold checkpoint
        lotCheckpoints[_lotId].push(Checkpoint({
            handler:   msg.sender,
            location:  "On-chain",
            action:    "Purchased",
            timestamp: block.timestamp,
            notes:     "Ownership transferred via AgriChain"
        }));

        emit LotPurchased(_lotId, msg.sender, totalPrice);
    }

    // ─── Views ───────────────────────────────────────────────────────────────
    function getLotCheckpoints(uint256 _lotId) external view lotExists(_lotId) returns (Checkpoint[] memory) {
        return lotCheckpoints[_lotId];
    }

    function getFarmerLots(address _farmer) external view returns (uint256[] memory) {
        return farmerLots[_farmer];
    }

    function getLot(uint256 _lotId) external view lotExists(_lotId) returns (ProduceLot memory) {
        return lots[_lotId];
    }

    function setPlatformFee(uint256 _bps) external onlyOwner {
        require(_bps <= 500, "Max 5%");
        platformFeeBps = _bps;
    }
}
