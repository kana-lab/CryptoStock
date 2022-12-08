pragma solidity ^0.5.4;

// 現在のところ、一度行った売買リクエストはキャンセルできない仕様
interface ICryptoStock {
    // 暗号株式の販売者登録
    function register() external;

    // 成売り、"買い板が足りる限り"amountを上限として成売りする
    function sellTaker(address stockName, uint32 amount) external;

    // 指値の売り
    function sellMaker(address stockName, uint32 amount, uint price) external;

    // 成買い, "送られてきたETHと売り板が足りる限り"amountを上限として成買いする
    function buyTaker(address stockName, uint32 amount) external payable;

    // 指値の買い, 約定していない段階でもETHを送る必要がある
    function buyMaker(address stockName, uint32 amount, uint price) external payable;

    function getPrice(address stockName) external view returns (uint);

    // 取引の成立時にemitされるイベント, 現在の価格を知るために用いる事ができる
    event Transfer(address stockName, address from, address to, uint32 amount, uint price);

    // 指値時にemitされるイベント, successは成否(2:買い成功, 1:売り成功, 0:失敗)
    event NewMaker(address stockName, address indexed from, uint32 amount, uint price, uint success);
}

// 暗号株式の発行数は企業毎に10000000で固定
// なんと暗号株式では価格決定までスマコン上で行われる
contract CryptoStock is ICryptoStock {
    struct Maker {
        address payable maker;
        uint price;  // in Wei
        uint32 amount;
        // 二分木の子ノードを表す
        uint left;
        uint right;
    }

    struct Stock {
        uint currentPrice;
        // 価格による二分探索木
        Maker[] sellTree;
        Maker[] buyTree;
        uint sellTreeRoot;
        uint buyTreeRoot;
    }

    // 企業毎の暗号株式の状態を格納
    mapping(address => Stock) stocks;

    // 各人がどれくらい暗号株式を持っているか？
    // 暗号株式銘柄 => 各人の辞書
    // 暗号株式銘柄は発行企業のウォレットアドレスで表す
    mapping(address => mapping(address => uint)) balances;

    // 将来的にはOwnerだけがregisterを呼べるようにし、上場審査を実現したい
    function register() external {
        // currentPrice != 0とすることで、stocks[msg.sender]が空でない事を示す
        stocks[msg.sender].currentPrice = 1;
        balances[msg.sender][msg.sender] = 10000000;
    }

    function getPrice(address stockName) external view returns (uint) {
        return stocks[stockName].currentPrice;
    }

    function sellMaker(address stockName, uint32 amount, uint price) external {
        // stockNameという銘柄が存在するかは確認する必要がない (お金の移動がないのでどうでも良い)
        require(balances[stockName][msg.sender] >= amount, "not enough stock");
        require(amount > 0, "amount must not be 0");

        Stock storage _stock = stocks[stockName];
        require(_stock.buyTree[_stock.buyTreeRoot].price < price, "invalid price");
        // 約定していなくともバランスを減らしてしまおう
        // 株を持っていないのに指値を連発されたら困るので。
        // バランスの復帰は指値のキャンセル機能を実装した時で良し
        balances[stockName][msg.sender] -= amount;

        uint _node = _stock.sellTreeRoot;
        Maker[] storage _sellTree = _stock.sellTree;
        // 二分探索！インサートしよう
        if (_node > 0) {
            while (true) {
                Maker memory _parent = _sellTree[_node];
                uint _node_backup = _node;
                _node = (price > _parent.price) ? _parent.right : _parent.left;

                if (_node == 0) {
                    _sellTree.push(Maker(msg.sender, price, amount, 0, 0));
                    uint idx = _sellTree.length - 1;
                    if (price > _parent.price) {
                        _sellTree[_node_backup].right = idx;
                    } else {
                        _sellTree[_node_backup].left = idx;
                    }
                    break;
                }
            }
        } else {
            _sellTree.push(Maker(address(0), 1, 0, 0, 0));
            // これ以外と重要だったりする
            _sellTree.push(Maker(msg.sender, price, amount, 0, 0));
            _stock.sellTreeRoot = 1;
        }

        // eventのemit
        emit NewMaker(stockName, msg.sender, amount, price, 1);
    }

    function buyTaker(address stockName, uint32 amount) external payable {
        Stock storage _stock = stocks[stockName];
        // stockNameなる銘柄が存在しているか？
        require(_stock.currentPrice > 0, "no such stock");

        Maker[] storage _sellTree = _stock.sellTree;
        uint _newRoot;
        uint _restAmount;
        uint _restEth;
        (_newRoot, _restAmount, _restEth) = _buy(
            stockName, _sellTree, _stock.sellTreeRoot, amount, msg.value
        );

        if (_stock.sellTreeRoot != _newRoot) {
            _stock.sellTreeRoot = _newRoot;
        }
        msg.sender.transfer(_restEth);
        balances[stockName][msg.sender] += amount - _restAmount;
        _stock.currentPrice = _sellTree[_newRoot].price;
    }

    function _buy(
        address _stockName,
        Maker[] storage _sellTree,
        uint _root,
        uint32 _amount,
        uint _eth
    ) internal returns (uint newChild, uint32 restAmount, uint restEth) {
        if (_root == 0) {
            return (0, _amount, _eth);
        }

        // 以下_rootは空ノードではない

        Maker memory _node = _sellTree[_root];
        uint _newChild;
        (_newChild, _amount, _eth) = _buy(
            _stockName, _sellTree, _node.left, _amount, _eth
        );

        if (_newChild > 0) {
            if (_node.left != _newChild) {
                _sellTree[_root].left = _newChild;
            }
            return (_root, _amount, _eth);
        }

        // 以下_newChild == 0 (左側のノード群は全て消費された)

        // _rootノードを食いつぶすか？
        uint _totalEth = _node.price * _node.amount;
        if (_totalEth <= _eth && _node.amount <= _amount) {
            _node.maker.transfer(_totalEth);
            emit Transfer(_stockName, msg.sender, _node.maker, _node.amount, _node.price);

            return _buy(
                _stockName, _sellTree, _node.right, _amount - _node.amount, _eth - _totalEth
            );
        }

        // 以下_rootノードを食いつぶさない場合

        // 左側のノード群を捨てる
        if (_node.left != _newChild) {
            _sellTree[_root].left = _newChild;
        }
        // 買える量を算出
        uint32 _buyableAmount = uint32(_eth / _node.price);
        // FIXME: 丸め方がへた
        if (_amount < _buyableAmount) {
            _buyableAmount = _amount;
        }
        _totalEth = _node.price * _buyableAmount;

        _node.maker.transfer(_totalEth);
        emit Transfer(_stockName, msg.sender, _node.maker, _buyableAmount, _node.price);

        _sellTree[_root].amount -= _buyableAmount;
        return (_root, _amount - _buyableAmount, _eth - _totalEth);
    }

    function buyMaker(address stockName, uint32 amount, uint price) external payable {
        require(amount * price == msg.value, "please send exact ETH");
        require(amount > 0, "amount must not be 0");

        Stock storage _stock = stocks[stockName];
        require(_stock.currentPrice > 0, "no such stock");
        require(_stock.sellTree[_stock.sellTreeRoot].price > price, "invalid price");

        // sellMakerとは違い、ここではバランスを調節しない
        // バランスを増やすと余分に売れる状態になってしまう

        uint _node = _stock.buyTreeRoot;
        Maker[] storage _buyTree = _stock.buyTree;
        // 二分探索！インサートしよう
        if (_node > 0) {
            while (true) {
                Maker memory _parent = _buyTree[_node];
                uint _node_backup = _node;
                _node = (price <= _parent.price) ? _parent.right : _parent.left;

                if (_node == 0) {
                    _buyTree.push(Maker(msg.sender, price, amount, 0, 0));
                    uint idx = _buyTree.length - 1;
                    if (price <= _parent.price) {
                        _buyTree[_node_backup].right = idx;
                    } else {
                        _buyTree[_node_backup].left = idx;
                    }
                    break;
                }
            }
        } else {
            _buyTree.push(Maker(address(0), 1, 0, 0, 0));
            _buyTree.push(Maker(msg.sender, price, amount, 0, 0));
            _stock.buyTreeRoot = 1;
        }

        // eventのemit
        emit NewMaker(stockName, msg.sender, amount, price, 2);
    }

    function sellTaker(address stockName, uint32 amount) external {
        require(balances[stockName][msg.sender] >= amount, "not enough stock");
        require(amount > 0, "amount must not be 0");

        Stock storage _stock = stocks[stockName];
        Maker[] storage _buyTree = _stock.buyTree;
        uint _newRoot;
        uint _restAmount;
        uint _totalEth;
        (_newRoot, _restAmount, _totalEth) = _sell(
            stockName, _buyTree, _stock.buyTreeRoot, amount, 0
        );

        if (_stock.buyTreeRoot != _newRoot) {
            _stock.buyTreeRoot = _newRoot;
        }
        msg.sender.transfer(_totalEth);
        balances[stockName][msg.sender] -= amount - _restAmount;
        _stock.currentPrice = _buyTree[_newRoot].price;
    }

    function _sell(
        address _stockName,
        Maker[] storage _buyTree,
        uint _root,
        uint32 _amount,
        uint _sumEth
    ) internal returns (uint newChild, uint32 restAmount, uint totalEth) {
        if (_root == 0) {
            return (0, _amount, _sumEth);
        }

        // 以下_rootは空ノードではない

        Maker memory _node = _buyTree[_root];
        uint _newChild;
        (_newChild, _amount, _sumEth) = _sell(
            _stockName, _buyTree, _node.left, _amount, _sumEth
        );

        if (_newChild > 0) {
            if (_node.left != _newChild) {
                _buyTree[_root].left = _newChild;
            }
            return (_root, _amount, _sumEth);
        }

        // 以下_newChild == 0 (左側のノード群は全て消費された)

        // _rootノードを食いつぶすか？
        if (_node.amount <= _amount) {
            _sumEth += _node.price * _node.amount;
            emit Transfer(_stockName, _node.maker, msg.sender, _node.amount, _node.price);

            return _sell(
                _stockName, _buyTree, _node.right, _amount - _node.amount, _sumEth
            );
        }

        // 以下_rootノードを食いつぶさない場合

        // 左側のノード群を捨てる
        if (_node.left != _newChild) {
            _buyTree[_root].left = _newChild;
        }

        _sumEth += _node.price * _amount;
        emit Transfer(_stockName, _node.maker, msg.sender, _amount, _node.price);

        _buyTree[_root].amount -= _amount;
        return (_root, 0, _sumEth);
    }
}
