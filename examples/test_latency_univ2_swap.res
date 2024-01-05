use ethers_contract::BaseContract;
use ethers_core::{abi::{parse_abi, Address, Token}};
use ethers_providers::{Http, Provider};
use revm::{
    db::EthersDB,
    primitives::{address, TransactTo, U256, AccountInfo, Address as RevmAddress, Bytecode, Account},
    Database, EVM, DatabaseCommit,
};
use revm_precompile::{B256, HashMap};
use std::{sync::Arc, time::{SystemTime, Instant}};

struct CachedEthersDb {
    ethersdb: EthersDB<Provider<Http>>,
    storage_overrides: HashMap<RevmAddress, HashMap<U256, U256>>,
    account_overrides: HashMap<RevmAddress, AccountInfo>,
}

impl Database for CachedEthersDb {
    /// The database error type.
    type Error = ethers_providers::ProviderError;

    /// Get basic account information.
    fn basic(&mut self, address: RevmAddress) -> Result<Option<AccountInfo>, Self::Error> {
        if let Some(value) = self.account_overrides.get(&address) {
            return Ok(Some(value.clone()));
        }
        let value = self.ethersdb.basic(address).unwrap().unwrap();

        self.account_overrides.insert(address, value.clone());

        Ok(Some(value))
    }

    /// Get account code by its hash.
    fn code_by_hash(&mut self, code_hash: B256) -> Result<Bytecode, Self::Error> {
        panic!();
    }

    /// Get storage value of address at index.
    fn storage(&mut self, address: RevmAddress, index: U256) -> Result<U256, Self::Error> {
        if let Some(account) = self.storage_overrides.get(&address) {
            if let Some(value) = account.get(&index) {
                return Ok(value.clone());
            }
        }
        println!("storage {} {}", address, index);
        let value =self.ethersdb.storage(address, index)?;

        let overrides = self.storage_overrides.entry(address).or_insert_with(|| HashMap::new());

        overrides.insert(index, value);

        Ok(value)
    }

    /// Get block hash by block number.
    fn block_hash(&mut self, number: U256) -> Result<B256, Self::Error> {
        println!("should not be called");
        self.ethersdb.block_hash(number)
    }
}

impl DatabaseCommit for CachedEthersDb {

    fn commit(&mut self, changes: HashMap<RevmAddress, Account>) {
        for (address, account) in changes {
            let account_storage = self.storage_overrides.entry(address).or_insert_with(|| HashMap::default());
            for (slot, value) in account.storage {
                account_storage.insert(slot, value.present_value);
            }
        }

    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // create ethers client and wrap it in Arc<M>
    let client = Provider::<Http>::try_from(
        // "https://mainnet.infura.io/v3/c60b0bb42f8a4c6481ecd229eddaca27",
        "http://127.0.0.1:8545",
    )?;
    let client = Arc::new(client);

    let router_address_2: Address = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D".parse().unwrap();

    let token0: Address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2".parse().unwrap();
    let token1: Address = "0xdAC17F958D2ee523a2206206994597C13D831ec7".parse().unwrap();

    let path = vec![Token::Address(token0), Token::Address(token1)];

    let fixed_array = Token::Array(path);
    let to: Address = "0x8eb8a3b98659cce290402893d0123abb75e3ab28".parse().unwrap();

    // generate abi for the calldata from the human readable interface
    let abi = BaseContract::from(
        parse_abi(&[
            "function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
            "function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external virtual override ensure(deadline) returns (uint[] memory amounts)",
            "function approve(address spender, uint256 value) external returns (bool)"
        ])?
    );


    // encode abi into Bytes
    // let encoded = abi.encode("getReserves", ())?;
    let encoded = abi
        .encode("swapExactTokensForTokens", (1000000000000000000 as u128, 2200000000 as u128, fixed_array, to, 1956910336 as u128))?;

    // initialize new EthersDB
    let ethersdb = EthersDB::new(Arc::clone(&client), None).unwrap();

    // initialise an empty (default) EVM
    let mut evm = EVM::new();

    let cached_ether_db = CachedEthersDb {
        ethersdb,
        storage_overrides: HashMap::new(),
        account_overrides: HashMap::new(),
    };
    // insert pre-built database from above
    evm.database(cached_ether_db);

    let encoded_approval = abi.encode("approve", (router_address_2, 1000000000000000000 as u128)).unwrap();

    evm.env.tx.caller = address!("8eb8a3b98659cce290402893d0123abb75e3ab28");
    evm.env.tx.value = U256::from(0);

    evm.env.tx.transact_to = TransactTo::Call(address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"));

    println!("{}", encoded_approval);
    evm.env.tx.data = encoded_approval.0.into();
    let ref_tx = evm.transact_commit().unwrap();

    println!("approval done");

    evm.env.tx.transact_to = TransactTo::Call(address!("7a250d5630b4cf539739df2c5dacb4c659f2488d"));
    evm.env.tx.data = encoded.0.into();

    let start = Instant::now(); // Start timing

    for i in 0..100000 {
        let ref_tx = evm.transact().unwrap();
    } 
    let duration = start.elapsed(); // End timing


    println!("duration {}", duration.as_millis());

    Ok(())
}
