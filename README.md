# CryptoStock
![alt text](../master/image/logo.png?raw=true)<br>

CryptoStockは2022.12.3-12.10に行われた[ブロックチェーンハッカソン](https://todaiweb3.com/hackathon/)
においてグループHが作成したものの一部であり、「暗号株式」を発行・売買するスマートコントラクトです。

# 用語

- 成り行き買い: 価格は気にせず、今すぐ株を買いたいという時に行う買い方
- 成り行き売り: 価格は気にせず、今すぐ株を売りたいという時に行う売り方
- 指値買い: 価格を指定しておき、株がその値段まで下がってきた時に自動的に買う買い方
- 指値売り: 価格を指定しておき、株がその値段まで上がってきた時に自動的に売る売り方

成り行き買い・成り行き売りは、必ず指値売り・指値買いを希望している人とマッチングします。
成り行き買いと成り行き売りがマッチングすることはありません。また、指値同士もマッチングしません。

成り行き買いでは、指値売りのうち最も安い値段を提示しているものから順に買われます。成り行き売りはその逆です。

指値売りの中で最も低い価格をPとして、P以上の値段で指値買いをする事はできません。逆も同様です。

# 仕様

CryptoStockでは、どの企業の株を売買するかという事を、その企業のウォレットアドレスを用いて指定します。
企業のウォレットアドレスはスマートコントラクトからは得られないので、別途入手する必要があります。

![alt text](../master/image/system.png?raw=true)
### 販売者登録

暗号株式を販売するには、`register`という関数を呼び出します。

### 成り行き売り

成り行き売りをするには、`sellTaker`という関数を呼び出します。引数は次の通りです:

- stockName (address型): 企業のウォレットアドレス。これによって株式の種類を伝える。
- amount (uint32型): 売る株式の数量。

ただし、指値買いを希望する人がいなくなったら`amount`に達していなくても取引は正常に終了します。

### 指値売り

指値売りをするには、`sellMaker`という関数を呼び出します。引数は次の通りです:

- stockName: 同上
- amount: 同上
- price: 希望の売却価格です。

### 成り行き買い

成り行き買いをするには、`buyTaker`という関数を呼び出します。引数は次の通りです:

- stockName: 同上
- amount: 買う株式の数量

以上の引数に加え、株を買うための資金となるイーサの数量を`value`というフィールドに入れなければなりません。
成り行き買いをすると、この数量分のイーサが自分のウォレットから引かれます。成り行き買いでは、株式を買い終えるまでに
いくら必要なのかが正確には分からないため、`value`の値を多めに設定します。超過した分はあとで返金されます。
`value`の値が小さいと`amount`分の株式の全てを買うことができませんが、買えるだけ買って取引は正常終了します。

### 指値買い

指値買いをするには、`buyMaker`という関数を呼び出します。引数は次の通りです:

- stockName: 同上
- amount: 同上
- price: 希望の購入価格です。

以上の引数に加え、株を買うための資金となるイーサの数量を`value`フィールドに入れる必要があります。
指値買いではこの数量が正確に求まるため、正確な値を入れて送ります。不正確である場合エラーとなります。

### 株式の現在の価格を取得する

特定の株式の現在の価格を取得する方法は2つあります。1つ目は`getPrice`関数を呼び出す方法です。
これは引数に`stockName`を取ります。2つ目は、`Transfer`イベントを常に監視する方法です。
`Transfer`イベントの`price`には最新の取引価格が入っています。
