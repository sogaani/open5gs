# Open5GS のネットワーク構成とサブネット設定

Open5GS 5GC (`ubuntu-latest-open5gs-build`)、WebUI (`open5gs-webui`)、MongoDB を Helm チャートで
デプロイするための個人メモ。以下の内容は本リポジトリの `configs/open5gs/*.yaml.in` と
`docs/_docs/guide/01-quickstart.md`、および https://open5gs.org/open5gs/docs/ に基づく。

---

## 1. デフォルトの「all-in-one」構成

サンプル設定はすべての NF を **1 台のホスト** で動かす前提になっている。各 NF が自分専用の
ループバックアドレスに bind することで、全デーモンが同じポート番号を衝突なく使え、デフォルトでは
ホストの外に何も公開されない。Linux は `127.0.0.0/8` 全体を `lo` に向けるので追加設定は不要
(macOS では `lo0` に alias を明示的に付ける必要があり、`meson-ci.yml` がそれをやっている)。

| NF   | bind アドレス | SBI (TCP) | その他のポート                               | 役割 |
|------|---------------|-----------|----------------------------------------------|------|
| NRF  | 127.0.0.10    | 7777      |                                              | NF の登録・発見 |
| SCP  | 127.0.0.200   | 7777      |                                              | SBI プロキシ (間接通信) |
| AMF  | 127.0.0.5     | 7777      | NGAP SCTP 38412, metrics 9090                | gNB シグナリング、登録、モビリティ |
| SMF  | 127.0.0.4     | 7777      | PFCP UDP 8805, GTP-C 2123, GTP-U 2152, metrics 9090 | PDU セッション制御、UE IP 払い出し |
| UPF  | 127.0.0.7     | -         | PFCP UDP 8805, GTP-U UDP 2152, metrics 9090  | ユーザプレーン、tun デバイス、NAT |
| AUSF | 127.0.0.11    | 7777      |                                              | 認証 |
| UDM  | 127.0.0.12    | 7777      |                                              | 加入者データのフロントエンド、SUCI 復号 |
| UDR  | 127.0.0.20    | 7777      | MongoDB クライアント                         | 加入者データストア (MongoDB を読む) |
| PCF  | 127.0.0.13    | 7777      | MongoDB クライアント, metrics 9090           | ポリシー (MongoDB を読む) |
| NSSF | 127.0.0.14    | 7777      |                                              | スライス選択 |
| BSF  | 127.0.0.15    | 7777      |                                              | バインディングサポート |
| WebUI| 0.0.0.0       | HTTP 9999 | MongoDB クライアント                         | 加入者登録 UI |

MME / HSS / SGW-C / SGW-U / PCRF は 4G (EPC) 側のもので、5G SA のラボなら省いてよい。

---

## 2. SBI: `127.0.0.5` が他の Pod を遮断する理由と対処

### `sbi.server` が決めるもの

```yaml
amf:
  sbi:
    server:
      - address: 127.0.0.5     # ソケットの bind アドレス
        port: 7777
```

このアドレスは 2 つの意味を持つ。

1. AMF はここで **listen** する。ループバックアドレスは同じ network namespace の中からしか
   到達できない。Kubernetes では Pod ごとに namespace が分かれるので、AMF Pod の `127.0.0.5` に
   SMF Pod からは届かない。つまりサンプル設定のままでは、他の Pod は AMF の SBI API を呼べない。
2. AMF はこのアドレスを NF プロファイルとして **NRF に登録** する。コンシューマ (SMF、PCF など) は
   NRF/SCP 経由で AMF を発見し、`127.0.0.5` を受け取る。AMF の前に Kubernetes Service を置いても、
   発見で返るのはループバックアドレスなので呼び出しは失敗する。

### `advertise` で「bind 先」と「他者に伝えるアドレス」を分ける

サンプル設定にも書かれている (`amf.yaml.in` の "SBI Server" コメントブロック)。

```yaml
amf:
  sbi:
    server:
      - dev: eth0                                        # または address: 0.0.0.0
        port: 7777
        advertise: open5gs-amf.open5gs.svc.cluster.local # NRF に登録される名前
    client:
      scp:
        - uri: http://open5gs-scp.open5gs.svc.cluster.local:7777
```

`advertise` にはホスト名か IP を指定でき、bind したポートと違うポートを広告したい場合は
`:port` を付ける (例: `open5gs-amf.svc:8888`)。同じキーは SMF と UPF の PFCP サーバ、GTP-U
サーバにもある。

### NF 同士の発見のしかた (SCP 経由の間接通信)

```
NF (AMF, SMF, ...) --> SCP (127.0.0.200) --> NRF (127.0.0.10)   発見
                                        --> producer NF         リクエスト転送
```

* 各 NF が固定で持つクライアントアドレスは **SCP の 1 つだけ**。
* SCP が固定で持つクライアントアドレスは **NRF の 1 つだけ**。
* それ以外はすべて NRF の登録情報から動的に発見されるため、全 NF で `advertise` が正しい必要がある。
* 直接通信も可能: `client.scp` をコメントアウトして各 NF に `client.nrf` を設定すると、各 NF が
  自分で NRF に問い合わせ、producer に直接アクセスする。ホップが減り Pod も 1 つ減る。

### SMF の選択 (`info` が必要な理由)

AMF は SMF が広告した `info` (S-NSSAI, DNN, TAI) を元に NRF から SMF を選ぶ。`info` のない SMF は
どの AMF からも選ばれうる。SMF が 1 つならデフォルトで問題ない。複数の SMF を置くなら、それぞれに
担当するスライスと DNN を列挙した `info` を与える。

---

## 3. SBI 以外のインターフェース

| インターフェース | 相手                  | プロトコル / ポート | 必要な到達性                       | 設定キー |
|------------------|-----------------------|---------------------|------------------------------------|----------|
| NGAP (N2)        | gNB -> AMF            | SCTP 38412          | **外部** (gNB から)                | `amf.ngap.server` |
| GTP-U (N3)       | gNB -> UPF            | UDP 2152            | **外部** (gNB から)                | `upf.gtpu.server` (+ `advertise`) |
| PFCP (N4)        | SMF <-> UPF           | UDP 8805            | 内部                               | `smf.pfcp.server/client.upf`, `upf.pfcp.server` |
| N6               | UPF -> Internet       | IP                  | UPF Pod からの egress              | `upf.session`, ホスト側 NAT |
| MongoDB          | UDR, PCF, WebUI       | TCP 27017           | 内部                               | `db_uri:` (udr/pcf yaml の先頭), WebUI は `DB_URI` 環境変数 |
| Metrics          | Prometheus -> NF      | HTTP 9090           | 内部                               | `<nf>.metrics.server` |

補足:

* gNB は PDU セッション確立時に AMF/SMF 経由で UPF の GTP-U アドレスを知る。これは UPF が
  `gtpu.server` で広告したアドレスなので、クラスタ内だけでなく **gNB から** ルーティング可能で
  なければならない。
* SMF -> UPF は `smf.pfcp.client.upf` に静的に書く (アドレスと、任意で `dnn`、`tac`、セル ID の
  セレクタ)。ここの UPF アドレスは DNS 名でもよい。
* WebUI は SBI を一切話さない。MongoDB の加入者データを読み書きするだけ。

---

## 4. UE サブネット ("session") の設定

### 役割分担

* **SMF** が IP プールを持つ。PDU セッション確立時に `smf.session` から UE アドレスを払い出し、
  UE にアドレス、DNS サーバ、MTU を通知する。
* **UPF** も **同じ** サブネットを知っている必要がある。`ogstun` から来た下りパケットを正しい
  GTP-U トンネルに振り分けるため。`upf.session` は `smf.session` と一致させる。
* **ホスト / Pod** 側で tun デバイスにゲートウェイアドレスを付け、N6 の egress 用に NAT を入れる。
  Open5GS 自身はこれをやらない。

### デフォルト設定

`smf.yaml.in` と `upf.yaml.in` には同じブロックが入っている。

```yaml
session:
  - subnet: 10.45.0.0/16
    gateway: 10.45.0.1
  - subnet: 2001:db8:cafe::/48
    gateway: 2001:db8:cafe::1
```

SMF 側にはさらに:

```yaml
dns:
  - 8.8.8.8
  - 8.8.4.4
  - 2001:4860:4860::8888
  - 2001:4860:4860::8844
mtu: 1400
```

* `subnet` がプール。ゲートウェイを除いてここから UE アドレスを払い出す。
* `gateway` は `ogstun` に付けるアドレスで、UE のデフォルトゲートウェイになる。
* `mtu: 1400` は 1500 バイトのトランスポート上で GTP-U/UDP/IP のオーバーヘッド分を空けるため。
* エントリに `dnn:` がなければ、そのプールは **どの DNN** にも使われる。

### DNN ごとのプール

各エントリに `dnn:` を付けると、DNN (APN) ごとに別のサブネットを使える。SMF と UPF の両方に同じ
一覧が必要。UPF 側は `dev:` でプールを別の tun デバイスに割り当てることもできる。

```yaml
# smf.yaml
session:
  - subnet: 10.45.0.0/16
    gateway: 10.45.0.1
    dnn: internet
  - subnet: 2001:db8:cafe::/48
    dnn: internet
  - subnet: 10.46.0.0/16
    gateway: 10.46.0.1
    dnn: ims
  - subnet: 2001:db8:babe::/48
    dnn: ims
```

```yaml
# upf.yaml  (同じサブネット。2 つ目の tun を使うなら dev: を付ける)
session:
  - subnet: 10.45.0.0/16
    gateway: 10.45.0.1
    dnn: internet
  - subnet: 10.46.0.0/16
    gateway: 10.46.0.1
    dnn: ims
    dev: ogstun3
```

設定コメントにある注意: UE が要求した DNN に対応するプールがないとセッション確立に失敗する
(古いバージョンでは SMF/UPF がクラッシュした)。`dnn:` なしのエントリを 1 つ残してキャッチオールに
するか、加入者の DNN が必ず一致するようにする。

### 払い出し範囲の制限

```yaml
session:
  - subnet: 10.45.0.0/16
    gateway: 10.45.0.1
    range:
      - 10.45.0.100-10.45.0.200
      - 10.45.1.100-        # 上限なし
      - -10.45.0.200        # サブネット先頭から
```

### UE の固定アドレス

WebUI の加入者設定 (Subscriber -> Slice -> Session) には任意項目の `UE IPv4 Address` /
`UE IPv6 Address` がある。設定されていれば SMF はプールから払い出さずそのアドレスを割り当てる。
UPF がルーティングできるように、設定済みの `subnet` の範囲内である必要がある。

### 複数の UPF

SMF は `smf.pfcp.client.upf` からセッションごとに UPF を選ぶ。

```yaml
smf:
  pfcp:
    client:
      upf:
        - address: upf-internet.open5gs.svc.cluster.local
          dnn: [internet, web]
        - address: upf-ims.open5gs.svc.cluster.local
          dnn: ims
```

TAC やセル ID でも選択できる。各 UPF は自分が担当する DNN の `session` エントリだけ持てばよい。

### UPF のホスト / Pod 側でやること (Open5GS はやらない)

quickstart と `docker/build/setup.sh` より:

```bash
# ゲートウェイアドレスを持つ tun デバイス (UPF は "ogstun" を開く。アドレスは事前に付けておく)
ip tuntap add name ogstun mode tun
ip addr add 10.45.0.1/16 dev ogstun
ip addr add 2001:db8:cafe::1/48 dev ogstun
ip link set ogstun up

# N6 egress
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
iptables  -t nat -A POSTROUTING -s 10.45.0.0/16      ! -o ogstun -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s 2001:db8:cafe::/48 ! -o ogstun -j MASQUERADE

# 任意の防御
iptables -I INPUT -i ogstun -j ACCEPT
iptables -I INPUT -s 10.45.0.0/16 -j DROP   # UE から UPF ホスト自身へ到達させない
```

Kubernetes では、UPF Pod に `NET_ADMIN`、`/dev/net/tun` デバイス、`net.ipv4.ip_forward` sysctl、
そして上記コマンドを実行する init ステップ (または entrypoint) が必要になる。UE のトラフィックは
Pod IP で出ていき、他の Pod トラフィックと同様にノードで再度 SNAT される。UE サブネットは Pod CIDR、
Service CIDR、ノードネットワークと重ねてはいけない。

### 加入者側も整合させる

MongoDB (WebUI 経由) の各加入者はスライス (`sst`/`sd`) とセッション (`dnn`、QoS、AMBR、任意の固定 IP)
を持つ。これらが次と一致している必要がある。

* `amf.plmn_support.s_nssai` と `nssf.sbi.client.nsi` (ネットワークが許可するスライス)
* `smf.info` があればそれ (SMF が担当するスライス/DNN の広告)
* `smf.session` / `upf.session` の `dnn:` エントリ (その DNN 用のプールがあること)

加入者のデフォルトテンプレートは `sst: 1`、`dnn: internet` で、設定のデフォルトと一致している。

---

## 5. Helm チャートへの落とし込み: チェックリスト

1. **NF ごとに Pod を分けるか、全 NF を 1 Pod に入れるか。**
   * 全 NF を 1 Pod にすると network namespace を共有するので、ループバック設定がそのまま使える。
     NGAP、GTP-U、metrics、MongoDB だけ実アドレスが必要。最初のチャートとしては最も簡単。
   * NF ごとに Pod を分けると、すべての SBI/PFCP/GTP-U サーバに `advertise`、すべてのクライアント
     URI に Service の DNS 名が必要。NF 単位でスケールでき、一般的な k8s の流儀に合う。
2. **設定は ConfigMap に**、NF ごとに YAML を 1 つ、`values.yaml` からレンダリングする (PLMN、TAC、
   スライス、DNN、UE サブネット、DNS、MTU、MongoDB URI)。
3. **Service**: SBI (7777) と PFCP (8805) は ClusterIP。NGAP 38412/SCTP と GTP-U 2152/UDP は gNB から
   到達できる必要がある (NodePort、LoadBalancer、または AMF/UPF Pod の `hostNetwork`)。UPF の GTP-U
   `advertise` は gNB が使うアドレスにする。
4. **UPF Pod**: `NET_ADMIN`、`/dev/net/tun` (hostPath または device plugin)、`ip_forward` sysctl、
   tun + iptables 用の init container、クラスタ CIDR と重ならない UE サブネット。
5. **MongoDB**: PVC 付き StatefulSet。`docs/assets/webui/mongo-init.js` で初期化 (WebUI の admin
   アカウントを作る)。UDR/PCF の `db_uri` と WebUI の `DB_URI` はその Service を指す。WebUI の
   entrypoint の待機用に `WAIT_HOSTS=<mongo-svc>:27017` も必要。
6. **起動順序**: NRF、次に SCP、それから残り。NF は NRF 登録をリトライするので厳密な順序は不要だが、
   TCP 7777 などの readiness probe があると楽。
7. **イメージ**: `ghcr.io/sogaani/ubuntu-latest-open5gs-build:<tag>` には全 NF のバイナリが
   `/usr/local/bin/open5gs-*d` に、サンプル設定が `/usr/local/etc/open5gs/` に入っているので、各 NF
   コンテナは同じイメージをコマンド違いで動かす (`open5gs-amfd -c /usr/local/etc/open5gs/amf.yaml`
   など)。そのディレクトリに ConfigMap をマウントする。WebUI は `ghcr.io/sogaani/open5gs-webui:<tag>`
   でポート 9999。

---

## 6. 参考構成: Qiita 記事のマルチ VM 構成

出典: s5uishida 氏「Open5GS 5GCとUERANSIM UE/RANによるシミュレーション携帯網」
(https://qiita.com/s5uishida/items/c22f82aea5614bb4c2d7)。設定の全文は
https://github.com/s5uishida/open5gs_5gc_ueransim_sample_config
(Open5GS v2.7.0、UERANSIM v3.2.6)。著者の目標は次のとおり。

* 1 つの C-Plane が **複数の U-Plane** (UPF) を持つ
* 1 つの U-Plane が **複数の DN** (データネットワーク) を持つ
* 複数の UE が **同じ DN** に接続する

### 6.1 トポロジ (記事の `network-overview.png` を描き直したもの)

```
                         VM1  Open5GS 5GC C-Plane
                         +---------------------------------------+
                         |  NRF SCP AUSF UDM UDR PCF NSSF BSF    |   SBI はすべて VM1 内の
                         |  MongoDB   (+ WebUI)                  |   127.0.0.x のまま
                         |      +-----+          +-----+         |
                         |      | AMF |          | SMF |         |
                         +------+--+--+----------+--+--+---------+
            .111                   |38412/sctp      |8805/udp  2152/udp
 192.168.0.0/24 ===================+================+=====================================
        |.132            |.131                 |.112                       |.113
        |                |                     |  2152/udp 8805/udp        |  2152/udp 8805/udp
  VM5 UERANSIM UE   VM4 UERANSIM gNodeB   VM2 U-Plane1 +-----+       VM3 U-Plane2 +-----+
  +---------------+ +------------------+  +------------| UPF |--+    +------------| UPF |--+
  | IMSI ...0000  |-| uesimtun0        |~~|  ogstun  10.45.0.1/16 |    |  ogstun3 10.47.0.1/16 |
  |               | | 10.45.0.2        |  |  DNN=internet          |    |  DNN=ims              |
  | IMSI ...0001  |-| uesimtun1 10.46.0.2 |  ogstun2 10.46.0.1/16 |    |                       |
  | IMSI ...0002  |-| uesimtun2 10.46.0.3 |  DNN=internet2         |    |                       |
  | IMSI ...0003  |-| uesimtun3 10.47.0.2 |------------------------+    | IMSI ...0003/0004     |
  | IMSI ...0004  |-| uesimtun4 10.47.0.3 |~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~>|                       |
  +---------------+ +------------------+  | MASQUERADE -> Internet |    | MASQUERADE -> Internet|
                                          +------------------------+    +-----------------------+
  ~~~ = GTP-U トンネル (N3)      --- = 制御 (N2 NGAP / N4 PFCP)
```

| VM  | 役割                    | IP               | 動かすもの |
|-----|-------------------------|------------------|------------|
| VM1 | 5GC C-Plane             | 192.168.0.111/24 | NRF, SCP, AMF, SMF, AUSF, UDM, UDR, PCF, NSSF, BSF, MongoDB, WebUI |
| VM2 | 5GC U-Plane1            | 192.168.0.112/24 | UPF (ogstun, ogstun2) |
| VM3 | 5GC U-Plane2            | 192.168.0.113/24 | UPF (ogstun3)。Raspberry Pi 4 でも動作確認済みの「エッジ」UPF |
| VM4 | UERANSIM gNodeB         | 192.168.0.131/24 | nr-gnb |
| VM5 | UERANSIM UE             | 192.168.0.132/24 | nr-ue x5 |

| DN (UE サブネット) | DN 側 tun (UPF) | DNN       | UE 側 tun             | U-Plane |
|--------------------|-----------------|-----------|-----------------------|---------|
| 10.45.0.0/16       | ogstun          | internet  | uesimtun0             | U-Plane1 (VM2) |
| 10.46.0.0/16       | ogstun2         | internet2 | uesimtun1, uesimtun2  | U-Plane1 (VM2) |
| 10.47.0.0/16       | ogstun3         | ims       | uesimtun3, uesimtun4  | U-Plane2 (VM3) |

| UE  | IMSI            | DNN       | 鍵 |
|-----|-----------------|-----------|-----|
| UE0 | 001010000000000 | internet  | OPc |
| UE1 | 001010000000001 | internet2 | OPc |
| UE2 | 001010000000002 | internet2 | OPc |
| UE3 | 001010000000003 | ims       | OPc |
| UE4 | 001010000000004 | ims       | OPc |

加入者は WebUI で登録し、K/OPc は 3GPP TS 35.208 のテストセット、それ以外はデフォルト
(スライス `sst: 1`、DNN は表のとおり)。

### 6.2 著者が変えた箇所とその理由

著者が従ったルール: **ホスト境界をまたぐものだけホストの LAN アドレスに移し、それ以外はループバックの
まま。** SBI のトラフィックは全部 VM1 内で完結するので、NRF/SCP/AMF/SMF/... の SBI アドレスは
`127.0.0.x` のままで、`advertise` も不要。

**PLMN** はサンプルの `999/70` から `001/01` に変更。`amf.yaml` (`guami`、`tai`、`plmn_support`)、
`nrf.yaml` (`serving`)、UERANSIM の gNB/UE ファイル。PLMN はすべての加入者の IMSI の先頭も含めて
全箇所で一致させる必要がある。

**amf.yaml** (VM1): VM4 の gNB から届く必要があるので N2 だけ移す。

```yaml
amf:
  sbi:
    server:
      - address: 127.0.0.5          # 変更なし: SBI は VM1 内で完結
        port: 7777
    client:
      scp:
        - uri: http://127.0.0.200:7777
  ngap:
    server:
      - address: 192.168.0.111      # N2: gNB から到達できるアドレス
  guami:
    - plmn_id: { mcc: 001, mnc: 01 }
      amf_id: { region: 2, set: 1 }
  tai:
    - plmn_id: { mcc: 001, mnc: 01 }
      tac: 1
  plmn_support:
    - plmn_id: { mcc: 001, mnc: 01 }
      s_nssai:
        - sst: 1
```

**smf.yaml** (VM1): N4 (PFCP) と SMF 自身の GTP-U を LAN に移す。UPF は DNN で選択。DNN ごとに
1 プール。IPv6 は削除。4G 専用の `gtpc` と `freeDiameter` も削除。

```yaml
smf:
  sbi:
    server:
      - address: 127.0.0.4          # 変更なし
        port: 7777
    client:
      scp:
        - uri: http://127.0.0.200:7777
  pfcp:
    server:
      - address: 192.168.0.111      # N4: UPF の VM に向けて
    client:
      upf:
        - address: 192.168.0.112    # U-Plane1
          dnn: [internet, internet2]
        - address: 192.168.0.113    # U-Plane2
          dnn: ims
  gtpu:
    server:
      - address: 192.168.0.111
  session:
    - subnet: 10.45.0.1/16          # 旧式の "ゲートウェイ/プレフィックス" 省略記法。現行 Open5GS も受け付けるが
                                    # subnet: 10.45.0.0/16 + gateway: 10.45.0.1 に直すよう警告が出る
      dnn: internet
    - subnet: 10.46.0.1/16
      dnn: internet2
    - subnet: 10.47.0.1/16
      dnn: ims
  dns:
    - 8.8.8.8
    - 8.8.4.4
  mtu: 1400
```

**U-Plane1 の upf.yaml** (VM2): N4 と N3 を LAN に bind、DNN ごとに tun を 1 つ。

```yaml
upf:
  pfcp:
    server:
      - address: 192.168.0.112
  gtpu:
    server:
      - address: 192.168.0.112      # gNB はここに GTP-U を送る
  session:
    - subnet: 10.45.0.1/16
      dnn: internet
      dev: ogstun
    - subnet: 10.46.0.1/16
      dnn: internet2
      dev: ogstun2
```

**U-Plane2 の upf.yaml** (VM3):

```yaml
upf:
  pfcp:
    server:
      - address: 192.168.0.113
  gtpu:
    server:
      - address: 192.168.0.113
  session:
    - subnet: 10.47.0.1/16
      dnn: ims
      dev: ogstun3
```

**各 U-Plane VM のホストネットワーク** (UPF 起動前):

```bash
# /etc/sysctl.conf に net.ipv4.ip_forward=1 を書いたうえで
sysctl -p

# U-Plane1
ip tuntap add name ogstun mode tun
ip addr add 10.45.0.1/16 dev ogstun
ip link set ogstun up
iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE

ip tuntap add name ogstun2 mode tun
ip addr add 10.46.0.1/16 dev ogstun2
ip link set ogstun2 up
iptables -t nat -A POSTROUTING -s 10.46.0.0/16 ! -o ogstun2 -j MASQUERADE

# U-Plane2
ip tuntap add name ogstun3 mode tun
ip addr add 10.47.0.1/16 dev ogstun3
ip link set ogstun3 up
iptables -t nat -A POSTROUTING -s 10.47.0.0/16 ! -o ogstun3 -j MASQUERADE
```

**UERANSIM** (VM4/VM5): gNB は `linkIp`、`ngapIp`、`gtpIp` の 3 つとも `192.168.0.131` に bind し、
`amfConfigs[0].address` を `192.168.0.111:38412` に向ける。各 UE ファイルは
`supi: imsi-00101000000000X`、`mcc: '001'`、`mnc: '01'`、`gnbSearchList: [192.168.0.131]`、
initial session に DNN を設定する。

**起動順序**: NRF、SCP、AMF (2 秒ずつ空ける)、残りの C-Plane NF、UPF、`nr-gnb`、`nr-ue`。
確認: gNB ログで NG Setup 成功、UE ホストに 10.45.0.2 を持つ `uesimtun0`、
`ping -I uesimtun0 google.com` しながら U-Plane1 で `tcpdump -i ogstun` に ICMP が見える。

### 6.3 この構成でのトラフィック経路

```
 制御 (N2)          UE --NAS--> gNB(VM4) --NGAP/SCTP 38412--> AMF(VM1 .111) --SBI 127.0.0.x--> SMF/AUSF/UDM/...
 セッション確立 (N4) SMF(VM1 .111) --PFCP/UDP 8805--> UPF(VM2 .112 または VM3 .113)   DNN で選択
 ユーザ (N3/N6)     UE uesimtun0 10.45.0.2 --GTP-U/UDP 2152--> UPF(VM2) ogstun 10.45.0.1 --MASQUERADE--> Internet
```

---

## 7. 同じ構成を Kubernetes で組む

### 7.1 VM 構成との違い

| VM 構成                                            | Kubernetes |
|----------------------------------------------------|------------|
| C-Plane の全 NF が VM1 の network namespace を共有 | Pod ごとに namespace が分かれる。ループバックでは NF がつながらない。 |
| SBI は `127.0.0.x`、`advertise` なし               | SBI は Pod IP (`dev: eth0`) に bind し、Service の DNS 名を広告する。 |
| クライアント設定に固定 LAN IP `192.168.0.11x`      | Service の DNS 名。例 `open5gs-smf.open5gs.svc.cluster.local`。 |
| gNB は LAN 上の AMF/UPF に直接届く                 | N2 (SCTP 38412) と N3 (UDP 2152) をクラスタ外に公開する必要がある。 |
| tun + iptables は VM 上で一度やる                  | UPF Pod 内で init container が行う。Pod に `NET_ADMIN` と `/dev/net/tun` が必要。 |
| UE トラフィックは VM の LAN IP に NAT              | UPF の **Pod IP** に NAT され、さらにノードの CNI でノード IP に NAT される。 |

以下で使うアドレス計画 (自分のクラスタに合わせて調整):

| 範囲              | 用途 |
|-------------------|------|
| 192.168.0.0/24    | ノード LAN。gNB (192.168.0.131) とノード (例 192.168.0.21, .22) がここにいる |
| 10.244.0.0/16     | Pod CIDR (例。flannel/calico のデフォルト) |
| 10.96.0.0/12      | Service CIDR (例) |
| 10.45/10.46/10.47.0.0/16 | UE サブネット (DN)。上のどれとも重ねない |

### 7.2 トポロジ

```
 192.168.0.0/24 (LAN)      gNB 192.168.0.131 ----NGAP sctp/38412-----------------+
                               |                                                 |
                               +----GTP-U udp/2152-----------------+             |
                                                                   |             |
 ==== Kubernetes クラスタ, namespace "open5gs" =====================|=============|==================
                                                                   v             v
   node A 192.168.0.21                                        NodePort/LB   hostNetwork または NodePort(SCTP)
   +-----------------------------------------------------------------------------------------------+
   |  Service (ClusterIP, DNS <name>.open5gs.svc.cluster.local)                                    |
   |   open5gs-nrf:7777  open5gs-scp:7777  open5gs-amf:7777  open5gs-smf:7777/8805                 |
   |   open5gs-ausf/udm/udr/pcf/nssf/bsf:7777   open5gs-upf1:8805  open5gs-upf2:8805               |
   |   mongodb:27017   open5gs-webui:9999                                                          |
   |                                                                                               |
   |  +-------+  +-------+  +-------+  +-------+  +------+ +-----+ +-----+ +-----+ +------+ +-----+ |
   |  |  NRF  |  |  SCP  |  |  AMF  |  |  SMF  |  | AUSF | | UDM | | UDR | | PCF | | NSSF | | BSF | |
   |  | pod   |<-| pod   |<-| pod   |  | pod   |  | pod  | | pod | | pod | | pod | | pod  | | pod | |
   |  +-------+  +-------+  +---+---+  +---+---+  +------+ +-----+ +--+--+ +--+--+ +------+ +-----+ |
   |        SBI http/7777 は SCP 経由 |          |  PFCP udp/8805           |        |  db_uri       |
   |                               |          +-------------+------------+--------+---> mongodb pod  |
   |                               |                        |                           (PVC)        |
   |   +---------------------------+--+   +-----------------v----------+   +---------------------+   |
   |   | UPF1 pod  (NET_ADMIN, /dev/net/tun, privileged init)        |   | UPF2 pod             |   |
   |   |  eth0 10.244.x.y   gtpu advertise = ノード/LB の IP          |   |  eth0 10.244.x.z     |   |
   |   |  ogstun  10.45.0.1/16  DNN=internet   --MASQ--> eth0 --> node|   |  ogstun3 10.47.0.1/16|   |
   |   |  ogstun2 10.46.0.1/16  DNN=internet2  --MASQ--> eth0 --> node|   |  DNN=ims             |   |
   |   +--------------------------------------------------------------+   +---------------------+   |
   |                                                                                               |
   |  +------------+   DB_URI=mongodb://mongodb/open5gs                                            |
   |  | WebUI pod  |------------------------------------------------> mongodb                      |
   |  +------------+  (ブラウザ用に Ingress/NodePort 9999)                                          |
   +-----------------------------------------------------------------------------------------------+
```

### 7.3 Kubernetes での NF ごとの設定

namespace は `open5gs`、Service 名は Pod の役割と同じ。以下は記事の値 (PLMN 001/01、DNN 3 つ、
UPF 2 つ) に合わせた「完成形」の YAML。

**nrf.yaml**

```yaml
nrf:
  serving:
    - plmn_id: { mcc: 001, mnc: 01 }
  sbi:
    server:
      - dev: eth0
        port: 7777
        advertise: open5gs-nrf.open5gs.svc.cluster.local
```

**scp.yaml**

```yaml
scp:
  sbi:
    server:
      - dev: eth0
        port: 7777
        advertise: open5gs-scp.open5gs.svc.cluster.local
    client:
      nrf:
        - uri: http://open5gs-nrf.open5gs.svc.cluster.local:7777
```

**amf.yaml**

```yaml
amf:
  sbi:
    server:
      - dev: eth0
        port: 7777
        advertise: open5gs-amf.open5gs.svc.cluster.local
    client:
      scp:
        - uri: http://open5gs-scp.open5gs.svc.cluster.local:7777
  ngap:
    server:
      - dev: eth0              # hostNetwork: true ならノードの LAN インターフェース
  metrics:
    server:
      - dev: eth0
        port: 9090
  guami:
    - plmn_id: { mcc: 001, mnc: 01 }
      amf_id: { region: 2, set: 1 }
  tai:
    - plmn_id: { mcc: 001, mnc: 01 }
      tac: 1
  plmn_support:
    - plmn_id: { mcc: 001, mnc: 01 }
      s_nssai:
        - sst: 1
```

**smf.yaml**

```yaml
smf:
  sbi:
    server:
      - dev: eth0
        port: 7777
        advertise: open5gs-smf.open5gs.svc.cluster.local
    client:
      scp:
        - uri: http://open5gs-scp.open5gs.svc.cluster.local:7777
  pfcp:
    server:
      - dev: eth0
        advertise: open5gs-smf.open5gs.svc.cluster.local   # UPF は PFCP association でこれを知る
    client:
      upf:
        - address: open5gs-upf1.open5gs.svc.cluster.local
          dnn: [internet, internet2]
        - address: open5gs-upf2.open5gs.svc.cluster.local
          dnn: ims
  gtpu:
    server:
      - dev: eth0
  metrics:
    server:
      - dev: eth0
        port: 9090
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1
      dnn: internet
    - subnet: 10.46.0.0/16
      gateway: 10.46.0.1
      dnn: internet2
    - subnet: 10.47.0.0/16
      gateway: 10.47.0.1
      dnn: ims
  dns:
    - 8.8.8.8
    - 8.8.4.4
  mtu: 1400
  info:                         # 任意: AMF がスライス/DNN でこの SMF を選べるようにする
    - s_nssai:
        - sst: 1
          dnn: [internet, internet2, ims]
```

**upf1.yaml**

```yaml
upf:
  pfcp:
    server:
      - dev: eth0
        advertise: open5gs-upf1.open5gs.svc.cluster.local
  gtpu:
    server:
      - dev: eth0
        advertise: 192.168.0.21        # gNB が GTP-U を送るべきアドレス (7.4 参照)
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1
      dnn: internet
      dev: ogstun
    - subnet: 10.46.0.0/16
      gateway: 10.46.0.1
      dnn: internet2
      dev: ogstun2
  metrics:
    server:
      - dev: eth0
        port: 9090
```

**upf2.yaml**: 同じ形で `open5gs-upf2`、`advertise: 192.168.0.22`、session は
`10.47.0.0/16 / ims / ogstun3` だけ。

**ausf, udm, udr, pcf, nssf, bsf**: `sbi.server` に `dev: eth0` + それぞれの `advertise`、
`sbi.client.scp` は SCP の Service を指す。UDR と PCF にはさらに

```yaml
db_uri: mongodb://mongodb.open5gs.svc.cluster.local/open5gs
```

**WebUI**: 環境変数 `DB_URI=mongodb://mongodb.open5gs.svc.cluster.local/open5gs` と
`WAIT_HOSTS=mongodb.open5gs.svc.cluster.local:27017`。ポート 9999 はブラウザ用に Ingress か
NodePort で公開するだけでよい。

### 7.4 N2 と N3 を gNB に公開する

gNB が触るのはこの 2 つだけで、どちらもクラスタ外から到達できる必要がある。

| 方式 | N2 (SCTP 38412, AMF) | N3 (UDP 2152, UPF) | 備考 |
|------|----------------------|--------------------|------|
| AMF と UPF の Pod に `hostNetwork: true` | gNB -> ノード IP | gNB -> ノード IP。ノード NIC に bind するので `gtpu.advertise` 不要 | 最も簡単でラボ用チャートに多い。ノードあたり AMF/UPF は 1 つ。UPF の tun + iptables はノードの namespace に作用するので、UE の NAT はそのままノード NIC から出る。 |
| NodePort / LoadBalancer Service | `protocol: SCTP` の Service (kube-proxy/CNI の SCTP 対応とノードの `sctp` カーネルモジュールが必要) | `protocol: UDP` の Service。`gtpu.advertise` にノード/LB の IP を設定 | Pod を Pod ネットワークに留められる。SMF は gNB に UPF の **広告した** GTP-U アドレスを伝えるので、それは外部アドレスでなければならない。 |
| Multus / 2 枚目の NIC (macvlan) | Pod が LAN IP を持つ | Pod が LAN IP を持ち、その NIC に N3 を bind | VM 構成に最も近い。Multus と NetworkAttachmentDefinition が必要。 |

どの方式でも gNB 側の設定の考え方は記事と同じ。`amfConfigs[0].address` = N2 の外部アドレス、
`gtpIp` = gNB 自身の LAN IP (UPF Pod は下りの GTP-U をここに送る。Pod からの LAN 宛て egress は
通常のノードルーティングで通る)。

### 7.5 UPF Pod の要件

```yaml
spec:
  initContainers:
    - name: netsetup
      image: ghcr.io/sogaani/ubuntu-latest-open5gs-build:sogaani-test
      securityContext:
        privileged: true              # Pod の netns で net.ipv4.ip_forward を書くのに必要
      command: ["/bin/sh", "-c"]
      args:
        - |
          sysctl -w net.ipv4.ip_forward=1
          ip tuntap add name ogstun  mode tun; ip addr add 10.45.0.1/16 dev ogstun;  ip link set ogstun  up
          ip tuntap add name ogstun2 mode tun; ip addr add 10.46.0.1/16 dev ogstun2; ip link set ogstun2 up
          iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun  -j MASQUERADE
          iptables -t nat -A POSTROUTING -s 10.46.0.0/16 ! -o ogstun2 -j MASQUERADE
  containers:
    - name: upf
      image: ghcr.io/sogaani/ubuntu-latest-open5gs-build:sogaani-test
      command: ["open5gs-upfd", "-c", "/usr/local/etc/open5gs/upf.yaml"]
      securityContext:
        capabilities:
          add: ["NET_ADMIN"]
      volumeMounts:
        - { name: tun, mountPath: /dev/net/tun }
        - { name: config, mountPath: /usr/local/etc/open5gs }
  volumes:
    - name: tun
      hostPath: { path: /dev/net/tun, type: CharDevice }
    - name: config
      configMap: { name: open5gs-upf1 }
```

init container が作った tun デバイスと iptables ルールは Pod の network namespace にあるので、
メインコンテナまで残る。ベースイメージには `iproute2` は入っているが `iptables` は入っていない
ので、MASQUERADE のステップに頼る前に `docker/ubuntu/latest/base/Dockerfile` に `iptables` を
追加する (または init 用に別イメージを使う)。

### 7.6 Kubernetes でのユーザプレーン経路

```
 UE 10.45.0.2  --GTP-U--> gNB 192.168.0.131 --udp/2152--> node 192.168.0.21 --(NodePort または hostNetwork)--> UPF1 pod
   --> デカプセル化 --> ogstun 10.45.0.1 --> MASQUERADE (src := Pod IP 10.244.x.y) --> eth0
   --> ノードの CNI で SNAT (src := 192.168.0.21) --> Internet
 下りはその逆: ノードと Pod の conntrack が 2 段の NAT を戻し、UPF は UE の TEID を付けて gNB の gtpIp に
 カプセル化する。
```

NAT が 2 段あってもラボ用途なら問題ない。UE アドレスを外から見せたい場合 (MEC や自前の DN) は
Pod 内の MASQUERADE をやめ、代わりにノードに `10.45.0.0/16` を UPF Pod IP 宛てにする経路を足すか、
Multus で UPF に 2 枚目の NIC を与える。

### 7.7 簡易版: C-Plane の全 NF を 1 Pod に入れる

```
   +------------------------------------------------------------------+
   | pod open5gs-cp (N2 用に hostNetwork、または NodePort SCTP)        |
   |  NRF 127.0.0.10  SCP 127.0.0.200  AMF 127.0.0.5  SMF 127.0.0.4   |   <- サンプル設定のまま
   |  AUSF UDM UDR PCF NSSF BSF は 127.0.0.1x                         |      ngap/pfcp/gtpu だけ変更
   |  amf.ngap  -> dev: eth0        smf.pfcp -> dev: eth0             |
   +------------------------------------------------------------------+
            |8805 PFCP                               db_uri -> mongodb svc
   +--------v---------+   +--------v---------+
   | pod upf1 (7.5)   |   | pod upf2 (7.5)   |
   +------------------+   +------------------+
```

記事の構成をそのまま写したもので、VM1 がマルチコンテナの 1 Pod、各 U-Plane VM が UPF Pod 1 つに
なる。サンプル設定から変えるのは `amf.ngap`、`smf.pfcp`、`smf.pfcp.client.upf`、`smf.gtpu`、`db_uri`
だけ。最初の Helm チャートとしては最も手間が少ない。7.3 の NF ごとの構成は、その先の発展形。

### 7.8 チャートの `values.yaml` の形 (案)

```yaml
plmn: { mcc: "001", mnc: "01" }
tac: 1
slices:
  - sst: 1
dnns:                      # DNN ごとに SMF (smf-<dnn>) と UPF (upf-<dnn>) を 1 組立てる。MVNO が SMF/UPF を持ち込む構成
  - name: internet
    subnet: 10.45.0.0/16
    gateway: 10.45.0.1
  - name: internet2
    subnet: 10.46.0.0/16
    gateway: 10.46.0.1
  - name: ims
    subnet: 10.47.0.0/16
    gateway: 10.47.0.1
    nodeSelector: { kubernetes.io/hostname: node-b }
amf:
  n2: { mode: hostNetwork }     # または nodePort
dns: [8.8.8.8, 8.8.4.4]
mtu: 1400
mongodb: { uri: mongodb://mongodb.open5gs.svc.cluster.local/open5gs }
image: { repository: ghcr.io/sogaani/ubuntu-latest-open5gs-build, tag: sogaani-test }
webui: { image: ghcr.io/sogaani/open5gs-webui, tag: sogaani-test }
```

テンプレートはこの値から `smf.session` (全 DNN)、各 UPF の `session` (担当 DNN だけ、`dev: ogstunN`
付き)、`smf.pfcp.client.upf` (DNN ごとにまとめた UPF の Service 名)、UPF の init container 用
スクリプトをレンダリングする。

---

## 8. データパスの内部: DN サブネット、ogstun、GTP-U、UERANSIM の無線リンク

### 8.1 DN サブネットに CNI の設定は必要か

ほぼ不要。UE サブネット (10.45.0.0/16, 10.46.0.0/16, ...) は CNI にとって存在しない。UE アドレスは
GTP-U のペイロードの中と、UPF Pod の network namespace 内の `ogstun` にしか現れない。UPF Pod 内で
MASQUERADE すれば、Pod から出るパケットの送信元はすべて Pod IP になるので、CNI からは普通の Pod
トラフィックに見え、戻りは conntrack が運ぶ。CNI 側に DN サブネットの IPAM も経路も不要。

これが成り立つ条件:

1. Pod CIDR、Service CIDR、ノード LAN、UE が到達すべき宛先のいずれとも **重複しない** こと。
   重複すると Pod 内の `ogstun` と `eth0` の経路が曖昧になり、NAT の戻り経路が壊れる。Cilium の
   cluster pool のデフォルト `10.0.0.0/8` は 10.45/10.46 を含むので要注意。flannel の `10.244.0.0/16`、
   kubeadm の Service `10.96.0.0/12` は問題ない。
2. このモデルでは **MASQUERADE が必須**。10.45.x.x を送信元のまま Pod から出すと CNI の anti-spoofing
   や `rp_filter` で落とされ、そもそも戻り経路もない。
3. UPF Pod の egress を絞る **NetworkPolicy** は UE のトラフィックも止める。

CNI の設定が必要になるのは、UE アドレスを NAT なしで到達可能にしたい場合だけ (MEC、UE *宛て* に
接続するサーバ、UE ごとの課金)。そのときはノードか CNI に「10.45.0.0/16 は UPF Pod IP 経由」という
経路が要る。Calico の BGP 広告、ノードの static route、Multus macvlan で UPF に LAN アドレスを
与える、のいずれか。

### 8.2 ogstun の正体と UPF のトンネル方式 (VXLAN ではない)

`ogstun` は Linux の素の **TUN** デバイス。Ethernet ヘッダのない L3 の仮想 NIC で、カーネルがここに
ルーティングしたパケットは `/dev/net/tun` を開いているプロセスが読み、プロセスが書いたパケットは
その NIC で受信したものとしてカーネルに見える。UPF は起動時にこれを開き (`src/upf/gtp-path.c`、
`ogs_tun_open`)、GTP-U の UDP ソケットと一緒に fd を監視する。`ogstun` に `10.45.0.1/16` を付けるのは、
下りパケットを UPF プロセスに導く connected route を作るため。

| 方向 | 引くキー | 処理 |
|------|---------|------|
| 上り (gNB -> UPF) | 外側の **TEID** | TEID -> PDR -> セッション。8 バイトの GTP-U ヘッダを外し、内側の送信元 IP がセッションの UE IP と一致するか確認し、内側の IP パケットを `ogstun` に書く (`ogs_tun_write`)。カーネルが forwarding し、MASQUERADE して `eth0` から出す。 |
| 下り (ogstun -> UPF) | 内側の **宛先 IP** | de-NAT された戻りパケットが `ogstun` にルーティングされる。UPF が読み (`ogs_tun_read`)、UE IP でセッションを引き (`upf_sess_find_by_ue_ip_address`)、FAR の gNB アドレスと下り TEID で GTP-U に包み、UDP 2152 で送る。 |

VXLAN との比較:

| | VXLAN | Open5GS UPF の GTP-U |
|---|---|---|
| カプセル化対象 | Ethernet フレーム (L2) | IP パケット (L3) |
| 外側 | UDP 4789、24bit VNI | UDP 2152、32bit TEID |
| トンネルの単位 | ネットワーク (VNI) ごと | PDU セッションごと、方向ごとに別 TEID |
| 処理場所 | カーネルの `vxlan` netdev | ユーザ空間の UPF プロセス + TUN |
| 相手の決め方 | FDB / フラッディング | SMF が PFCP (PDR/FAR) で設定 |

含意: パケットごとにカーネルとユーザ空間を往復するので、スループットはカーネル内トンネルより劣る
(ラボなら問題ない。eUPF などの eBPF/XDP ベースの UPF や Linux の `gtp` モジュールはカーネル内で処理
する)。Kubernetes では TUN と UDP ソケットが UPF Pod の中に完結するので、CNI は GTP-U をただの UDP
として見るだけ。8.1 が成り立つのはこのため。

### 8.3 UE IP アドレスの所有者

* UE IP (例 10.46.0.2) は **UE** のもので、gNB のものではない。gNB はトンネルを中継するだけで、内側の
  アドレスは見ない。
* **SMF** が `smf.session` から払い出し、NAS の PDU Session Establishment Accept で (AMF と gNB 経由で)
  UE に届け、どの UE IP、上り TEID、gNB アドレス、下り TEID がそのセッションのものかを PFCP で UPF に
  教える。UPF は PDR/FAR の状態を保持するだけ。
* UE にとっても N6 側 (`ogstun` から先) にとっても本物のアドレス。ただしトランスポート網
  (192.168.0.0/24) には現れず、そこには外側ヘッダしか流れない。
* 上りは TEID で、下りは UE IP そのもので振り分ける。つまり UE IP はラベルではなく、実際の経路制御と
  セッション検索に使われている。

```
 UE 10.46.0.2            gNB                     UPF Pod (ogstun 10.46.0.1)         Internet
 内側: 10.46.0.2 -> 8.8.8.8   外側: 192.168.0.131 -> UPF :2152 +TEID   NAT 後: PodIP -> 8.8.8.8
```

### 8.4 UERANSIM の UE <-> gNB リンクの模擬 (RLS)

UERANSIM は NAS と RRC を実装するが、**PHY/MAC/RLC/PDCP は実装していない**。無線は Radio Link
Simulation プロトコルに置き換えられており、これは UDP ポート **4997** の素の UDP
(`src/utils/constants.hpp` の `RadioLinkPort`)。

* `nr-gnb` は `linkIp:4997` で listen する。`nr-ue` は `gnbSearchList` の各アドレスに HEARTBEAT を
  送り、gNB は HEARTBEAT_ACK を返す。電波強度 (dBm) は設定上の仮想座標から計算され、-120 dBm 未満の
  セルは無視される。これがセルサーチ。
* それ以外はすべて PDU_TRANSMISSION メッセージで、ペイロードの種別が `RRC` (制御) か `DATA`
  (ユーザプレーン) かだけ違う。`DATA` PDU には **PDU セッション ID (psi)** と生の IP パケットが入る。
  UE<->gNB の LAN 区間を流れるのは GTP でも VXLAN でもなく、「UDP 4997 の中の IP パケット」。

**UE 側: UE IP は送信元であって宛先ではない。** PDU セッションが受け入れられると、`nr-ue`
(`src/ue/tun/config.cpp`) は次と等価の処理を行う。

```bash
ip tuntap add uesimtun1 mode tun                 # PDU セッションごとに 1 つ
ip addr add 10.46.0.2/32 dev uesimtun1
ip link set uesimtun1 up
# /etc/iproute2/rt_tables にテーブル名を追加したうえで
ip rule  add from 10.46.0.2 table <uesimtun1用テーブル>
ip route add default dev uesimtun1 table <uesimtun1用テーブル>
```

これは **送信元ベースのポリシールーティング**。送信元が UE IP のパケットだけがセッション専用の
テーブルを引き、そのデフォルト経路が TUN になっている。ホストのメイン経路表は触らない。だから使い方が
「インターフェースに bind する」になる: `ping -I uesimtun1` (SO_BINDTODEVICE で送信元が 10.46.0.2 に
なる) や `nr-binder 10.46.0.2 curl ...` (アプリのソケットを UE IP に bind する)。
`nr-ue --no-route-config` なら TUN だけ作って経路は自分で設定する。

**上りの経路**

```
UE ホスト (192.168.0.132)                gNB ホスト (192.168.0.131)              UPF
+------------------------------+        +---------------------------------+
| app: src 10.46.0.2 -> 8.8.8.8|        | nr-gnb                          |
|  ip rule from 10.46.0.2      |        |  UDP 4997 受信                   |
|  default dev uesimtun1       |        |  UE ctx + psi -> N3 トンネル     |
| nr-ue: TUN fd から read      |        |   (UPF IP, 上り TEID は NGAP の  |
|  RLS DATA(psi=1, IP パケット) |--UDP-->|    PDU Session Resource Setup)  |--UDP 2152--> ogstun -> NAT -> Internet
|  -> 192.168.0.131:4997       |        |  gtpIp:2152 から GTP-U 送信      |
+------------------------------+        +---------------------------------+
```

**下りの経路**: UPF -> 下り TEID 付きで `gtpIp:2152` -> `nr-gnb` が TEID から UE + psi を引く ->
HEARTBEAT で覚えた UE のアドレスに RLS DATA を UDP 送信 -> `nr-ue` が `uesimtun1` に書く ->
カーネルは `uesimtun1` に 10.46.0.2 宛てのパケットが届いたと見なし、bind 済みソケットにローカル配送。

**ホップのまとめ**

| 区間 | 仕組み | 識別子 |
|------|--------|--------|
| app -> nr-ue | TUN `uesimtunN` + 送信元ベースの `ip rule` | 送信元 IP |
| nr-ue -> nr-gnb | RLS over UDP 4997 | UE コンテキスト + psi |
| nr-gnb -> UPF | GTP-U over UDP 2152 | TEID |
| UPF -> DN | TUN `ogstun` | 宛先 IP |

UE IP は両端の TUN では本物として扱われ、その間の 2 ホップはどちらもユーザ空間の UDP カプセル化。
実機の gNB なら RLS のホップが本物の無線スタックに置き換わるだけで、GTP-U と UPF の動作は同じ。

---

## 9. N2 と SCTP

### 9.1 gNB と AMF の間で SCTP を使う理由

N2 (NGAP) のトランスポートは 3GPP TS 38.412 で SCTP と規定されている。負荷分散や地理分散のためというより、
**電話網の信号リンクの要件** に由来する。

* NGAP (5G) も S1AP (4G) も SS7 の信号網を IP に載せる SIGTRAN の流れにあり、そのために IETF が設計したのが
  SCTP (RFC 4960)。「常時張りっぱなしで途切れてはいけない信号リンク」を TCP より安全に運ぶのが目的。

| SCTP の機能 | N2 で効く理由 |
|---|---|
| メッセージ境界の保持 | NGAP は ASN.1 の 1 メッセージ単位で処理する。TCP のバイトストリームだと自前で区切りが必要 |
| マルチストリーム | 1 アソシエーション内に独立した複数ストリーム。TCP だと 1 パケットの再送待ちで後続全部が止まる (head-of-line blocking) が、UE ごと・手順ごとに別ストリームにして他の UE を止めない。UERANSIM の `ignoreStreamIds` はこのストリーム番号の扱い |
| マルチホーミング | 1 アソシエーションに複数の IP (経路) を結びつけ、経路障害時に自動で切り替える |
| HEARTBEAT による経路監視 | トランスポート層で経路の死活を数秒単位で検知する |
| 4-way ハンドシェイク + Cookie | SYN flood 型攻撃に強い。常時公開される信号ポートには重要 |

冗長性と負荷分散がどの層にあるか:

* **リンク障害**: SCTP のマルチホーミング。ローカルな回線や NIC の二重化が主目的で、地理分散を直接担うものではない。
* **AMF の負荷分散・AMF 障害**: SCTP ではなく **NGAP 層**。gNB は AMF Set 内の複数 AMF と同時にアソシエーションを
  張り、NG Setup Response の Relative AMF Capacity に応じて UE を振り分ける。AMF が落ちれば同じ Set の別 AMF に
  割り当て直し、AMF 側は UE コンテキストを UDSF などで引き継ぐ。1 つの AMF に複数アソシエーション (TNLA) を
  張る仕組みもある。
* **地理的分散**: AMF Set を複数サイトにまたがって構成して実現する。SCTP は「1 本のアソシエーションを落とさない」
  部分だけを受け持つ。

### 9.2 マルチホーミングの実体とプログラムからの見え方

「複数 NIC に同時に接続が張られる」のではなく、**1 本のアソシエーションが複数のアドレスペア (経路) を持ち、
データは通常そのうち 1 本 (primary path) だけを流れ、残りは backup path として待機・監視される**。

* TCP のコネクションは 4 つ組 (src IP:port, dst IP:port) 1 つで識別される。SCTP のアソシエーションは
  「ローカルのアドレス集合」×「相手のアドレス集合」で識別される (内部的には Verification Tag)。
* INIT / INIT-ACK で両端が自分の全アドレスを通知し合う。相手のアドレスを 1 つしか知らなくても、INIT-ACK で
  残りが伝わって経路に加わる。
* primary で `Path.Max.Retrans` 回再送に失敗すると backup に切り替わる。再送だけ別経路に流す動きもある。
* 標準の Linux SCTP は複数経路の同時利用 (CMT) はしない。あくまでフェイルオーバー。

サーバ側: ソケットは 1 つ。`bind()` の代わりに複数アドレスを渡せる `sctp_bindx()` を使う。`INADDR_ANY` に bind
すればホストの全アドレスが自動的に含まれる。

```c
int sk = socket(AF_INET, SOCK_SEQPACKET, IPPROTO_SCTP);
struct sockaddr_in addrs[2];                    /* NIC1, NIC2 */
sctp_bindx(sk, (struct sockaddr *)addrs, 2, SCTP_BINDX_ADD_ADDR);
listen(sk, 5);
```

クライアント側: 指定するのは IP アドレスのままだが、`connect()` の代わりに複数の相手アドレスを渡せる
`sctp_connectx()` がある。複数渡すのは「最初の INIT をどこに送るか」の候補を増やすため。

```c
int sk = socket(AF_INET, SOCK_SEQPACKET, IPPROTO_SCTP);
sctp_bindx(sk, local_addrs, 2, SCTP_BINDX_ADD_ADDR);   /* 自分側も複数 NIC を使うなら */
struct sockaddr_in peers[2];                            /* AMF の 2 アドレス */
sctp_assoc_t assoc_id;
sctp_connectx(sk, (struct sockaddr *)peers, 2, &assoc_id);
```

接続後にアプリが扱うのは 1 つの fd (assoc_id) だけで、どの経路を通ったかは意識しない。経路を見たり制御したり
する API:

| API / ソケットオプション | 用途 |
|---|---|
| `sctp_getpaddrs()` / `sctp_getladdrs()` | 相手側 / 自分側のアドレス一覧 |
| `SCTP_PRIMARY_ADDR` | primary にする相手アドレスの指定 |
| `SCTP_PEER_ADDR_PARAMS` | 経路ごとの HEARTBEAT 間隔や `Path.Max.Retrans`。Open5GS の `ogs_sctp_peer_addr_params()` が `spp_hbinterval` を設定している |
| `SCTP_PEER_ADDR_CHANGE` 通知 | 経路のダウン・復帰・primary 変更のイベント |

Open5GS では `lib/sctp/ogs-lksctp.c` の `ogs_sctp_server()` が設定から得たアドレスのリストをまとめて
`sctp_bindx()` し、クライアント側は `sctp_connectx()` を使う。

Kubernetes の Pod は通常 IP を 1 つしか持たないので、Multus などで 2 枚目の NIC を付けない限りマルチホーミングは
効かない。UERANSIM の gNB も `ngapIp` は 1 つ。Pod 障害からの回復は Kubernetes の再スケジュールと NGAP 層の
AMF Set に頼る。

### 9.3 Kubernetes (Cilium) で SCTP が通らなかった件

症状: gNB が AMF の Pod IP に SCTP 接続を試み `Connection timed out`。AMF は `10.0.9.53:38412` で LISTEN 済み。

切り分けの結果:

* カーネルモジュールは問題なかった。gNB Pod と AMF Pod の両方で `/proc/modules` に `sctp` があり、
  `/proc/net/sctp` も存在し、`/proc/net/protocols` に SCTP が載っていた (これらは netns ではなくホスト全体の
  情報なので、任意の Pod から確認できる)。
* NetworkPolicy / CiliumNetworkPolicy はなし。
* gNB 側ノードの Cilium で `cilium-dbg monitor -v` を取りながら gNB Pod から `sctp_test` で INIT を送ると、
  Pod を出た直後にドロップが記録された。

```
xx drop (CT: Unknown L4 protocol) flow 0x0 to endpoint 0, ifindex 35, file bpf_lxc.c:502,
   identity 27694->unknown: 10.0.0.105:49177 -> 10.0.9.53:38412 sctp
```

* UE Pod から gNB Pod への `sctp_test` (どちらも UERANSIM イメージ、ノードをまたぐ) も届かず、Open5GS や
  UERANSIM 固有ではなくクラスタ全体で Pod 間 SCTP が落ちていた。
* 原因は `cilium-config` の `enable-sctp: false` (Cilium v1.20.2、routing-mode tunnel/vxlan)。Cilium の conntrack が
  SCTP を未知の L4 として egress で破棄する。

対処 (クラスタ全体の設定変更。Cilium エージェントのローリング再起動を伴う):

```bash
helm -n kube-system upgrade cilium cilium/cilium --version 1.20.2 --reuse-values --set sctp.enabled=true
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.enable-sctp}'   # true
kubectl -n open5gs rollout restart deploy/open5gs-gnb-gnb1
kubectl -n open5gs logs -f deploy/open5gs-gnb-gnb1   # "NG Setup procedure is successful"
```

診断に使ったコマンド:

```bash
# Pod 内から SCTP の利用可否
kubectl -n open5gs exec <pod> -- sh -c 'grep -i sctp /proc/net/protocols; grep sctp /proc/modules; ls /proc/net/sctp'
# AMF が SCTP で listen しているか (ss -S は SCTP ソケット)
kubectl -n open5gs exec <amf-pod> -- ss -S -l -n
# Cilium のドロップ監視 (対象 Pod のノード上の cilium Pod で)
kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- cilium-dbg monitor --type drop
# UERANSIM イメージには lksctp-tools が入っているので、能動的に INIT を送る試験ができる
kubectl -n open5gs exec <gnb-pod> -- sctp_test -H 0.0.0.0 -P 0 -h <amf-pod-ip> -p 38412 -s -c 1 -x 1
```

補足: `sctp_darn -s` は標準入力からデータを送るまで INIT を出さないので、接続試験には `sctp_test` の
クライアントモードを使う。

### 9.4 UERANSIM の設定に k8s の FQDN を使えるか

UERANSIM v3.3.0 では使える (v3.2.x は IP 文字列のみ)。

* gNB の `amfConfigs[].address`、`linkIp` / `ngapIp` / `gtpIp` は `GetIpAddress()` (`src/utils/yaml_utils.cpp`) で
  「FQDN を `getaddrinfo` で解決 → IP → インターフェース名」の順に解釈される。`eth0` と書けば Pod IP になる。
  `gtpAdvertiseIp` で bind する IP と AMF に通知する GTP-U アドレスを分けることもできる。
* UE の `gnbSearchList` は文字列のまま保持され、`InetAddress(name, 4997)` のコンストラクタが `getaddrinfo` を
  呼ぶ (`src/utils/network.cpp`) ので FQDN でよい。
* 解決は起動時に 1 回だけ。headless Service のレコードは Pod が Ready になるまで存在しないので、先に起動すると
  プロセスが終了して CrashLoopBackOff で再試行になる。entrypoint の「解決できるまで待つ」ループは残す価値がある。
  相手 Pod の IP が変わっても自動追従はしない (gNB Pod の再起動が必要)。

---

## 10. 参考

* Quickstart (tun、NAT、ファイアウォール、加入者登録):
  https://open5gs.org/open5gs/docs/guide/01-quickstart/
* 全オプションのコメント付きサンプル設定: `configs/open5gs/amf.yaml.in`、
  `smf.yaml.in`、`upf.yaml.in`、`nrf.yaml.in`、`scp.yaml.in`
* ローカル実行用の Docker compose 構成: `docker/docker-compose.yml`
* build イメージが使う tun/経路設定スクリプト: `docker/build/setup.sh`
* マルチ VM の参考構成 (Qiita): https://qiita.com/s5uishida/items/c22f82aea5614bb4c2d7
* その設定の全文: https://github.com/s5uishida/open5gs_5gc_ueransim_sample_config
* UERANSIM: https://github.com/aligungr/UERANSIM/wiki
