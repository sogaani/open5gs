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
  「FQDN を `getaddrinfo` で解決 → IP → インターフェース名」の順に解釈される。FQDN と IP は使える。
  ただし **インターフェース名 (`eth0`) は v3.3.0 では動かない**: 先に呼ばれる `TryResolveHost()` が
  解決失敗時に値を空文字で上書きするため、後続のインターフェース検索が空文字を受け取り
  `Field 'linkIp' must be a valid IP address...` で起動に失敗する。bind アドレスは downward API の
  Pod IP を `__POD_IP__` に sed で埋める方式にしている。
  `gtpAdvertiseIp` で bind する IP と AMF に通知する GTP-U アドレスを分けることもできる。
* UE の `gnbSearchList` は文字列のまま保持され、`InetAddress(name, 4997)` のコンストラクタが `getaddrinfo` を
  呼ぶ (`src/utils/network.cpp`) ので FQDN でよい。
* 解決は起動時に 1 回だけ。headless Service のレコードは Pod が Ready になるまで存在しないので、先に起動すると
  プロセスが終了して CrashLoopBackOff で再試行になる。entrypoint の「解決できるまで待つ」ループは残す価値がある。
  相手 Pod の IP が変わっても自動追従はしない (gNB Pod の再起動が必要)。

---

## 10. スライス (S-NSSAI / SST) と SMF・UPF の選択

### 10.1 SST とは

S-NSSAI = SST (Slice/Service Type、1 バイト) + 任意の SD (Slice Differentiator、24 bit)。
標準値は 1=eMBB、2=URLLC、3=MIoT、4=V2X、128〜255 は事業者独自。
Open5GS も UERANSIM も SST の「意味」は解釈しない。QoS や経路を直接変えることはなく、
**「どの UE が、どの gNB 経由で、どの SMF/UPF に接続できるか」を照合するタグ**として働く。

### 10.2 Open5GS で SST が照合される 4 か所

| 場面 | 照合する相手 | 不一致のときの挙動 | コード |
|---|---|---|---|
| gNB ↔ AMF (NG Setup) | gNB が広告するスライス vs `amf.plmn_support.s_nssai` | 1 つも一致しないと NG Setup Failure | `src/amf/ngap-handler.c` `s_nssai_is_found()` |
| UE 登録 (Registration) | UE の Requested NSSAI、UDM から得た加入者データ (`slice[].sst`)、`amf.plmn_support` の共通部分 = Allowed NSSAI | 共通部分が空なら `No Allowed-NSSAI` で登録拒否 | `src/amf/nudm-handler.c` `amf_update_allowed_nssai()` |
| PDU セッション確立 | UE が送る S-NSSAI + DNN vs 加入者データの `slice[].session[].name` と Allowed NSSAI | 一致するスライスがなければセッション拒否 | `src/amf/gmm-handler.c` (UL NAS Transport) |
| SMF 選択 | AMF が NRF に S-NSSAI + DNN で検索 vs SMF の `info.s_nssai[].sst` と `dnn` | SST の違う SMF は候補にならない | `lib/sbi/context.c` `ogs_sbi_check_smf_info_slice()` |

Helm チャートでは次の 3 つの値を同じにしておく必要がある。

* `slices[].sst` → AMF `plmn_support`、NSSF、gNB `slices`、SMF `info` に展開 (ネットワーク側)
* `subscribers[].sst` → MongoDB の加入者データ `slice[0].sst` (`default_indicator: true`)
* `ues[].sst` → UERANSIM の `sessions[].slice`、`configured-nssai`、`default-nssai`

### 10.3 「同じ DNN 名で SST が違うとき、別の UPF に振り分けられるか」

**SMF を分ければできる。1 つの SMF の中ではできない。**

1 つの SMF 内の UPF 選択は `src/smf/context.c` の `compare_ue_info()` で行われ、照合キーは
`dnn`、`tac`、`e_cell_id` (4G)、`nr_cell_id` (5G) の 4 つだけ。S-NSSAI は見ていない。
同じ DNN 名の UPF が 2 つあるとどちらも一致するので、ラウンドロビンで選ばれる。
一致する UPF がない場合は `global.parameter.no_pfcp_rr_select` を立てない限り他の UPF に
フォールバックするので、分離を厳密にしたいときはこの設定を有効にする。

一方 AMF → SMF の選択は S-NSSAI + DNN で行われるので、SMF の `info` を分ければ同じ DNN 名でも
SST ごとに別の SMF、したがって別の UPF に到達する。

```yaml
# smf-a (upf-a を持つ)
smf:
  info:
    - s_nssai:
        - sst: 1
          dnn: [internet]
  pfcp:
    client:
      upf:
        - address: upf-a
          dnn: internet

# smf-b (upf-b を持つ)
smf:
  info:
    - s_nssai:
        - sst: 2
          dnn: [internet]
  pfcp:
    client:
      upf:
        - address: upf-b
          dnn: internet
```

同時に必要な設定:

* `amf.plmn_support.s_nssai` と gNB の `slices` に SST 1 と 2 の両方を入れる。
* 加入者データの `slice[]` で、その UE に許可する SST を分ける。SST 2 で `internet` を使う UE には
  `sst: 2` の slice に `session[].name: internet` が必要。
* UERANSIM の UE 設定で `sessions[].slice.sst` を使い分ける。
* UE の IP プール (`session.subnet`) は SMF ごとに持つので、SST 1 と SST 2 で別サブネットにする
  (必須ではないが推奨。理由は 10.6)。

### 10.4 これは 3GPP 標準の制約か、Open5GS の制約か

**Open5GS の実装上の制約。** 標準では SMF 内の UPF 選択に S-NSSAI を使うことが明確に規定されている。

* TS 23.501 6.3.3 (UPF 選択): S-NSSAI、DNN、UE の位置 (TAI)、UPF の能力、負荷、PDU セッションタイプ
  などが選択基準として列挙されている。
* TS 29.510 (NRF): UPF の NF プロファイルに `upfInfo.sNssaiUpfInfoList[]` があり、その中に
  `dnnUpfInfoList[]` が入る。「この UPF は SST 1 の internet と SST 2 の internet を担当する」と登録し、
  SMF が S-NSSAI + DNN で UPF を検索する設計。
* TS 23.501 6.3.2 (SMF 選択): AMF が S-NSSAI + DNN で SMF を選ぶ。こちらは Open5GS も
  `smfInfo.sNssaiSmfInfoList` として実装している。

Open5GS が省略している部分:

* UPF は NRF に登録されず、SMF は `pfcp.client.upf` の静的リストから選ぶ。
* その静的リストの照合キーに S-NSSAI がない (`compare_ue_info()`)。
* UPF 側の `session` 設定も DNN 単位で、S-NSSAI 単位の IP プールは持てない。

商用コアや free5GC のように NRF ベースの UPF 選択を持つ実装では、1 つの SMF がスライスごとに
別の UPF へ振り分けられる。

### 10.5 MVNO 検証への含意

フル MVNO が自前の SMF と UPF をセットで持ち込む構成は、Open5GS の制約と標準の両方に合う。
AMF から見れば S-NSSAI + DNN で MVNO の SMF が選ばれ、その先の UPF は MVNO 側で閉じるからである。
「SST だけで分けて SMF を MNO と共用する」構成だけが Open5GS では再現できない。

チャートでは `dnns[]` の各エントリに任意の `sst` (と `sd`) を持たせられる。

* `sst` なし: `smf-<dnn>` / `upf-<dnn>`。SMF `info` には `values.slices` の全 S-NSSAI を広告 (従来どおり)。
* `sst` あり: `smf-<dnn>-sst<N>[-sd<hex>]` / `upf-<dnn>-sst<N>[-sd<hex>]`。SMF `info` にはその S-NSSAI だけを
  広告するので、同じ DNN 名でもスライスごとに別の SMF/UPF ペアに到達する。
* `sst`/`sd` が `values.slices` にない場合は `helm template` 時点で fail させている (AMF が拒否するため)。
* 加入者 (`subscribers[].sst`) と UE (`ueransim.ues[].sst`) 側も対応する SST にする。

```yaml
slices: [{ sst: 1 }, { sst: 2 }]
dnns:
  - { name: internet, sst: 1, subnet: 10.45.0.0/16, gateway: 10.45.0.1 }   # MNO
  - { name: internet, sst: 2, subnet: 10.46.0.0/16, gateway: 10.46.0.1 }   # MVNO
```

### 10.6 UPF が異なれば UE サブネットも分けなければならないか

**原理的にはどちらの制約でもない。分けるのは IP ルーティングと一部の実装上の都合。**

3GPP 側 (TS 23.501 5.8.2.2 IP address management、TS 29.244 Network Instance IE):

* UE の IP は PDU セッション単位で SMF (または UPF / 外部 DHCP・AAA) が払い出す。プールは DNN + S-NSSAI に紐づく。
* **異なる DN (Network Instance) の間では IP 空間の重複が明示的に許される。** PFCP の Network Instance IE は
  まさに「同じアドレス帯を別の VRF/DN で使う」ための識別子。
* 同じ DN に複数の UPF をぶら下げる場合、UE 宛の下り方向パケットをどの UPF に届けるかを DN 側のルータが
  判断する必要があるため、UE アドレスを DN にそのまま広報する (NAT しない) 構成では UPF 間で重複できない。
  これはプロトコルの制約ではなく IP ルーティングの要請。UPF で NAT するなら UE IP は DN に出ないので重複できる。

Open5GS 側:

* SMF / UPF のプールはプロセス内でしか管理されない。重複チェック (`ogs_pfcp_check_subnet_overlapping()`)
  は 1 プロセス内の同じ DNN の `session` 同士にしかかからず、別 SMF・別 UPF との調整は一切ない。
  つまり「重複してもよい」のではなく「重複を知らない」。
* k8s では UPF Pod ごとに netns が分かれ、`ogstun` と MASQUERADE も Pod 単位なので、重複プールでも
  IP レベルでは動く (上りは各 Pod IP に NAT、下りは TEID で振り分け)。全 NF を 1 ホストに置く VM 構成では
  `ogstun` が同じ経路表に乗るので重複できない。これはホスト側の制約。
* **BSF は PCF バインディングを UE IPv4 だけでハッシュしている** (`src/bsf/context.c`
  `bsf_sess_find_by_ipv4addr()`)。TS 29.521 では ipv4Addr + dnn + snssai + ipDomain で引けるが、Open5GS は
  IP 単独。スライス間で同じ UE IP が出ると BSF のバインディング表が衝突する。影響するのは AF
  (IMS の P-CSCF など) が UE IP から PCF を引く経路だけで、単純なインターネット接続には影響しない。

結論: チャートでは `dnns[]` エントリごとに別サブネットを推奨する。必須ではないが、BSF の衝突を避けられ、
ログやキャプチャの UE IP からスライスを特定できる。

---

## 11. ローミング (SEPP / Home-Routed) でフル MVNO を模擬する

### 11.1 構成

フル MVNO = 自前の PLMN (999/71) と加入者 DB を持ち、MNO (999/70) の RAN と AMF を借りる事業者。
3GPP ではそのまま「V-PLMN = MNO、H-PLMN = MVNO の Home-Routed (HR) ローミング」になる。

```
 namespace open5gs (MNO, V-PLMN 999/70)             namespace mvno (MVNO, H-PLMN 999/71)
 ┌──────────────────────────────────────────┐      ┌──────────────────────────────────────────┐
 │ gNB ──N2── AMF ──SBI── SCP ── NRF        │      │  NRF ── SCP ──SBI── AUSF / UDM / UDR     │
 │  │          │           │                │      │          │          PCF / NSSF / BSF      │
 │  │          │        SEPP ═══ N32-c/f ═══╪══════╪═══ SEPP  │                                │
 │  │          │        (7778/7779, TLS)    │      │          └──── H-SMF (smf-internet)      │
 │  │       V-SMF (smf-internet-sst1 ...)   │      │                 │ N4                      │
 │  │          │ N4                         │      │              H-UPF (10.50.0.0/16, NAT)    │
 │  └─N3── V-UPF ══════ N9 (GTP-U, Pod IP) ═╪══════╪════════════════┘                          │
 └──────────────────────────────────────────┘      └──────────────────────────────────────────┘
```

* MVNO に置くもの: NRF、SCP、SEPP、AUSF、UDM、UDR、PCF、BSF、NSSF、H-SMF、H-UPF、MongoDB、WebUI
  (`helm/open5gs-mvno`)。
* MNO に残るもの: gNB、AMF、NRF、SCP、SEPP、V-SMF、V-UPF、V-PCF、NSSF、BSF (`helm/open5gs` の
  `roaming.enabled: true`)。**V-SMF/V-UPF は HR ローミングでも必須** (N16 で H-SMF、N9 で H-UPF につなぐ)。
* 制御信号は SBI → SCP → SEPP → (N32) → SEPP → SCP → NF と流れる。N9 (GTP-U) は V-UPF と H-UPF の
  Pod IP 同士で直接。SEPP を通らない。

### 11.2 Open5GS がローミングと判定する条件

* AMF は SUCI の PLMN (= UE のホーム PLMN) が **serving PLMN リスト**に無ければローミング扱いにする
  (`lib/sbi/context.c` `ogs_sbi_plmn_id_in_vplmn()`)。serving PLMN は `nrf.serving.plmn_id` に設定し、
  NRF 登録応答で全 NF に配られる。チャートは以前から `nrf.serving` を出しているので、999/71 の SUCI は
  何もしなくてもローミング扱い (SEPP が無いと `No SEPP` で失敗するだけ)。
* AMF のログ `Home-Routed Roaming` / `Local Breakout` で判別。HR と LBO は加入者データの
  `slice.session.lbo_roaming_allowed` で決まる (未設定 = HR)。
* AMF は `access_control` に列挙したホーム PLMN の加入者だけ受け入れる (`roaming.peers[]` から生成)。

### 11.3 SEPP に向く条件 = 3GPP 形式の FQDN

NF がリクエストを SEPP に送るのは、**宛先 apiRoot のホストが `<label>.5gc.mnc<MNC3>.mcc<MCC3>.3gppnetwork.org`
で、その PLMN が serving PLMN と違うとき**だけ (`lib/sbi/path.c`、`src/scp/sbi-path.c`)。IP や k8s の
Service 名を advertise していると SEPP を経由せず直接接続しようとして失敗する。

* したがって相手 PLMN から到達される NF はこの形式を advertise する:
  H-PLMN: NRF、AUSF、UDM、NSSF、SMF。V-PLMN: NRF と SMF (H-SMF からのコールバック先)。
  `advertise: <fqdn>:7777` とポートを付ける (無いと 80 になる)。
* ラベル部分は自由 (パースは末尾の `mncXXX.mccYYY` だけ) なので、チャートはコンポーネント名を
  そのまま使う: `smf-internet-sst1.5gc.mnc070.mcc999.3gppnetwork.org`。
* **advertise のホスト名は NF 起動時に `ogs_addaddrinfo()` + assert で解決される**
  (`lib/sbi/context.c`)。SCP も同一 PLMN 宛の Target-apiRoot を解決し、AMF は NSSF が返す NRF URI に
  直接接続する。そこで対象 Service の ClusterIP を固定し (`roaming.fqdnNfs`、`dnns[].clusterIP`)、
  全 NF Pod に `hostAliases` を注入している (CoreDNS の rewrite でも代替可)。
* 例外 (重要): 相手 PLMN の NF を指す apiRoot は **NF インスタンスの FQDN からポート無しで作られる**
  ことがある。V-NRF が合成する `nrf.<domain>` (`ogs_nrf_fqdn_from_plmn_id()`)、V-AMF が V-SMF に渡す
  `hSmfUri` (`http://smf-internet.5gc.mnc071...` → H-SCP が 80 番に接続してタイムアウトした) など。
  チュートリアルの設定が全部ポート無し (= 80) なのはこのため。チャートでは 3GPP FQDN を advertise する
  Service すべてに 80→7777 を追加して吸収している。NRF のラベルは `nrf` 固定。

### 11.4 SEPP の設定

```yaml
sepp:
  default: { tls: { server: {private_key, cert, verify_client, verify_client_cacert},
                    client: {cacert, client_private_key, client_cert} } }
  sbi:  { server: [{address: __POD_IP__, port: 7777, advertise: <k8s FQDN>}], client: {scp: [...]} }
  n32:
    server:
      - sender: open5gs-sepp.open5gs.svc.cluster.local   # 自分の N32 識別子
        scheme: https
        address: __POD_IP__
        port: 7778                                      # N32-c
        n32f: { scheme: https, address: __POD_IP__, port: 7779 }
    client:
      sepp:
        - receiver: mvno-sepp.mvno.svc.cluster.local    # 相手の sender と完全一致が必要
          uri: https://mvno-sepp.mvno.svc.cluster.local:7778
          n32f: { uri: https://mvno-sepp.mvno.svc.cluster.local:7779 }
```

* `sender`/`receiver` は N32-c の `SecNegotiateReqData.sender` で交換され、受信側は
  `sepp_node_find_by_receiver()` で完全一致検索する。TLS の SNI とは無関係。証明書の CN/SAN は
  `uri` のホストと一致させる (`helm/sepp-certs/make-certs.sh`)。
* 相手 SEPP がどの PLMN を担当するかは N32-c で相手が送ってくる serving PLMN から学ぶ。
  そのため各 SEPP は先に自 PLMN の NRF に登録されている必要がある。
* セキュリティ能力は TLS のみ (PRINS 無し)。
* 既知の挙動: 相手が先に接続してきて、こちらがまだ NRF 登録前だと
  `Assertion 'OGS_FSM_STATE(&sepp_node->sm)' failed` で一度落ちて再起動する。再起動後は確立する。
* 既知の挙動 2: N16 の作成がタイムアウトすると、UE の再送時に V-SMF が
  `Assertion 'sess->pdu_session_resource_uri'` で落ちる。その後 AMF に古い SM コンテキストが残り、
  再登録時に SMF からの 404 を受けて `5GS services not allowed` で拒否し続ける。AMF の再起動で解消。
* 成功ログ: `[<receiver>] SEPP established`。

### 11.5 HR ローミングのデータパス

1. UE (hplmn 999/71) が MNO gNB に登録 → V-AMF がローミング判定 → AUSF/UDM の探索に
   target-plmn-list を付けて V-NRF → (V-SCP → V-SEPP → H-SEPP → H-SCP) → H-NRF → H-AUSF/H-UDM。
2. PDU セッション: V-AMF が V-NSSF → H-NSSF (SEPP 越し) → H-NRF で H-SMF を見つけ、V-NRF で
   S-NSSAI + DNN から V-SMF を選ぶ。V-SMF に `hSmfUri` を渡す。
3. V-SMF が V-UPF を確保し、N16 (`PduSessionCreateData`) を H-SMF へ (SEPP 越し)。
   `vsmfPduSessionUri` にはコールバック先として V-SMF の 3GPP FQDN が入る。
4. H-SMF/H-UPF が UE IP を MVNO のプール (10.50.0.0/16) から払い出し、`hcnTunnelInfo` (H-UPF の
   GTP-U アドレス = Pod IP) を返す。V-UPF ↔ H-UPF の N9 は Pod IP 同士の GTP-U。
5. UE の上り: gNB → V-UPF → N9 → H-UPF → ogstun → MASQUERADE (H-UPF Pod IP) → インターネット。
   MVNO 側で「自網の加入者」として課金・ポリシーを扱える。

DNN 名は両 PLMN に必要 (V-SMF の選択も DNN で行う)。H-SMF の `info` に `tai` を書くと
V-PLMN の TAI と一致しないので書かない。V-PCF には UDR データが無いので `pcf.policy` に
加入者 SUPI 範囲のローカルポリシーを持たせる (AM ポリシー用。SM ポリシーは H-PCF)。

### 11.6 H-PLMN 宛の通信で「誰が・何をもとに・何を判断するか」

| 順 | モジュール | 判断材料 | 判断・動作 |
|---|---|---|---|
| 1 | V-AMF | SUCI の PLMN と、NRF 登録時に配られた serving PLMN リスト | `ogs_sbi_plmn_id_in_vplmn()` が真ならローミング加入者。`access_control` に無い PLMN は拒否 |
| 2 | V-AMF | ローミング判定 | AUSF/UDM/NSSF/SMF の探索に `target-plmn-list`(ホーム)と `requester-plmn-list`(自網)を付ける |
| 3 | V-SCP | 探索ヘッダ | V-NRF に転送するだけ。PLMN は見ない |
| 4 | V-NRF | `nrf.serving` と `target-plmn-list` | 自 PLMN に一致が無ければ H-NRF へ転送。URI は `hnrf-uri` があればそれ、無ければ `nrf.5gc.mnc<MNC>.mcc<MCC>.3gppnetwork.org` を合成。NRF は SCP を持たないので登録済みの SEPP に直接送る |
| 5 | V-SEPP | `3gpp-Sbi-Target-apiRoot` の FQDN 末尾 (`mncXXX.mccYYY`) | 他 PLMN → MCC/MNC を切り出し `sepp_node_find_by_plmn_id()` で相手 SEPP を選び N32-f で送る。相手の PLMN は N32-c で相手が申告した serving PLMN から学習 |
| 6 | H-SEPP | Target-apiRoot の PLMN が自分と同じ | 内向き要求として自分の SCP に渡す |
| 7 | H-SCP | Target-apiRoot (自 PLMN) | ホスト名を OS リゾルバ (hostAliases) で解決して NF に接続。**3GPP FQDN を実際に解決するのはここだけ** |
| 8 | H-NRF | `requester-plmn-list`、serving PLMN | 自 PLMN のプロファイルを返す (各 NF が advertise した 3GPP FQDN 入り) |
| 9 | V-AMF | 加入者データの `lbo_roaming_allowed` | 未設定 = Home-Routed。V-NSSF/H-NSSF 経由で H-SMF を探し、V-NRF で V-SMF を選んで `hSmfUri` を渡す |
| 10 | V-SMF | `SmContextCreateData` に `hSmfUri` があるか | あれば HR の V-SMF。V-UPF を確保して N16 を `hSmfUri` へ (経路は 5→6→7) |
| 11 | H-SMF | N16 の `vsmfPduSessionUri`、`vcnTunnelInfo` | H-UPF で UE IP を払い出し `hcnTunnelInfo` を返す。以後のコールバックは `vsmfPduSessionUri` 宛 |
| 12 | V-UPF / H-UPF | PFCP で渡された F-TEID | PLMN の概念なし。N9 は Pod IP 同士の GTP-U |

要点:

* ローミングかどうかを判断するのは AMF だけ。SCP と SEPP は UE を知らず、ヘッダの FQDN に埋まった PLMN ID
  だけで「自 PLMN なら解決して接続、他 PLMN なら SEPP へ」を機械的に行う。
* SEPP は 3GPP FQDN を名前解決しない。SEPP が相手を選ぶ根拠は設定の `receiver` ではなく N32-c で学習した PLMN。
* NRF が PLMN をまたぐ唯一の「転送者」。ほかの NF は探索結果の apiRoot に従うだけ。
* V 網内で完結する通信に 3GPP FQDN が要らないのは「PLMN をまたぐ判定が一度も起きないから」。NRF が
  アドレスを配る仕組み自体はローミングでも同じで、違うのは名前に PLMN ID が埋まっているかどうかだけ。
* V 側の `roaming.fqdnNfs` が小さいのは、H 側から呼ばれる NF が V-SMF (コールバック) くらいしか無いため。
  H-UDM → V-AMF の通知も SEPP 経由にしたければ `amf` を追加する。

### 11.7 `nrf.5gc.mnc071.mcc999.3gppnetwork.org` と `hnrf-uri`

* この名前は 3GPP が決めた形式。TS 23.003 28.3.2 がホーム網ドメイン `5gc.mnc<MNC3>.mcc<MCC3>.3gppnetwork.org`
  を、28.3.2.3.2 が NRF の FQDN `nrf.<ドメイン>` を定める。`3gppnetwork.org` は公開 DNS ではなく GSMA が
  IPX 向けに運用する私設 DNS 空間 (IR.67)。「PLMN ID が分かれば相手網の NRF の名前が機械的に決まる」のが
  標準の建付けで、Open5GS の `ogs_nrf_fqdn_from_plmn_id()` (`lib/proto/types.c`) がその実装。
* `hnrf-uri` は AMF に静的設定するものではなく **NSSF から動的に受け取る**。ローミング時に V-NSSF が H-NSSF に
  問い合わせ、H-NSSF の `NsiInformation.nrfId` にホーム網の NRF URI が入る (TS 29.531)。Open5GS の
  `src/amf/nnssf-handler.c` はこれを `sess->nssf.hnrf_uri` に保存し、以後の探索で NRF に渡す。
  NRF は `hnrf-uri` があればそのホストを、無ければ上の形式で合成した名前を H-NRF として使う。
* 今回のログで両方が見える: 登録時 (AUSF/UDM 探索、NSSF 未経由) は `hnrf_uri:NULL` で合成、
  PDU セッション時 (SMF 探索) は `hnrf_uri:http://nrf.5gc.mnc071...:7777/nnrf-disc/v1/nf-instances`。
* Open5GS に「相手 PLMN → H-NRF URI」を AMF/NRF に書く設定は無い。登録先は **H-PLMN の NSSF の `nsi[].uri`**
  で、これが `nrfId` として返る。だからこの URI は k8s の Service 名ではなく 3GPP 形式でなければならない
  (V 側の各ホップが PLMN を判定できる必要がある)。
* AMF が「事前にローミング先を知っている」に相当するのは `access_control` (受け入れるホーム PLMN) と
  SEPP の `n32.client.sepp[]` (N32 を張る相手) だけ。どの NF にどう届けるかは PLMN ID から決まる FQDN と
  NSSF が返す `nrfId` で実行時に解決される。事業者を追加しても全 NF の設定を触らずに済む設計。

### 11.8 UERANSIM に当てたパッチ (`docker/ueransim/patches/`)

| パッチ | 内容 |
|---|---|
| 0001 UE PLMN 選択 | `performPlmnSelection()` は HPLMN と Equivalent PLMN しか候補にしないため、999/71 の UE は 999/70 のセルで LIMITED SERVICE 止まりだった。TS 23.122 の自動モード (iv)「禁止されていない他 PLMN」を候補に加える。 |
| 0002 gNB AMF 選択 | v3.3.0 は Registration Request の Requested NSSAI で AMF を選ぶ。Service Request など NSSAI の無い初期 NAS では `Could not find a suitable AMF` になり、CM-IDLE からの復帰や gNB 再起動後に UE が二度と復帰しなかった。接続中の任意の AMF にフォールバックする。 |
| 0003 gNB Requested NSSAI | 同じコードが IE 不在時に optional を参照していた (UB)。IE を**削除する動作は維持**する: Open5GS は Initial UE Message の Registration Request に非 cleartext IE (Requested NSSAI など) があると `Non cleartext IEs is included` で拒否する (TS 24.501 4.4.6)。AMF は加入者データのデフォルト S-NSSAI で動く。 |

RAN 共用方式 (gNB が 999/71 を報知し、AMF の tai/plmn_support に 999/71 を追加) でも UE 無改造で
動くが、UE は自網だと思い込み、AMF が NRF の serving PLMN の都合でローミング扱いにするだけの
ハイブリッドになる (ホーム側に届く servingNetwork も 999/71)。HR ローミングを忠実に再現するなら UE パッチ方式。

### 11.9 実網ではどう届くか: S-NAPTR ではなく SEPP、IPX、GSMA

Open5GS の N32 は「ピア SEPP を設定で直書き」だが、実網では V-PLMN から H-PLMN へ
どう経路が決まるのかを整理しておく。

#### EPC と 5GC の違い (S-NAPTR の位置づけ)

| | EPC (TS 29.303) | 5GC SBI (TS 29.500 / 33.501) |
|---|---|---|
| H 側ノードの探し方 | MME が `apn.epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org` を GRX/IPX DNS で S-NAPTR 解決し、H-PGW の IP を得る | 名前 (`nrf.5gc.mnc071.mcc999...`) を得るだけで、V 側は IP を引かない |
| 越境通信の送り先 | H-PGW の IP へ直接 (IPX は IP 転送) | 自網の V-SEPP。V-SEPP → H-SEPP (N32) → H-SCP/H-NF |
| H 側内部の名前解決 | V 側 resolver が IPX DNS 経由で行う | H-SEPP / H-SCP が H-PLMN 内部 DNS で行う |

- `.3gppnetwork.org` はインターネットに存在しない私設ドメイン (GSMA IR.67)。ルートを GSMA が
  指名した事業者が IPX 網上で運用し、各事業者が `mnc<MNC>.mcc<MCC>.3gppnetwork.org` 配下の
  権威 DNS を IPX 側に公開する。S-NAPTR はこの DNS 上の仕組みで、主に EPC のノード選択に使う。
- 5GC では「越境かどうか」を **FQDN 内の PLMN ID** で判定し (TS 29.500 6.1.4.3)、越境なら
  宛先を自網の SEPP に付け替えて本来の宛先を `3gpp-Sbi-Target-apiRoot` に入れる。もう一つの
  標準手段が **telescopic FQDN** (TS 23.003): `nrf.5gc.mnc071.mcc999...` を
  `nrf-5gc-mnc071-mcc999.sepp.5gc.mnc070.mcc999.3gppnetwork.org` のように SEPP 配下の名前に
  書き換え、自網 DNS でそれを V-SEPP に向ける (V 側で TLS 証明書検証を成立させるため)。
  どちらでも V 側 NF が解決するのは自網 SEPP の名前だけで、IPX DNS に H-PLMN 内 NF の
  A レコードを置く必要はない。
- H-SEPP は Target-apiRoot (または telescopic FQDN から復元した元 FQDN) を取り出して
  H-SCP/H-NF に転送し、`smf-internet.5gc.mnc071...` の解決は H-PLMN 内部 DNS が行う。
  今回のチャートではこれを hostAliases + 固定 ClusterIP で代用しており、MNO 側は MVNO 内の
  FQDN を一切解決していない。
- N9 (V-UPF ↔ H-UPF) は DNS を使わない。H-SMF が N16 応答で H-UPF の IP/TEID を返し、
  V-UPF はその IP に GTP-U を IPX の IP 網で直接送る。

#### V-SEPP が H-SEPP を知るまでの三段階

1. **PLMN ID → H-SEPP の名前 (計算で決まる)**: GSMA NG.113 が
   `sepp.5gc.mnc<MNC>.mcc<MCC>.3gppnetwork.org` と形式を定めているので、ディレクトリ
   サービスは不要。Open5GS が `ogs_nrf_fqdn_from_plmn_id()` で NRF 名を合成するのと同じ発想。
2. **名前 → IP**: 実網では次の二通りを併用する。
   - IPX DNS (動的): IPX 網上の `3gppnetwork.org` ルート DNS → PLMN ゾーンの NS/glue →
     H 事業者の権威 DNS が公開する `sepp.5gc...` の A/AAAA。委譲登録は H 事業者が GSMA 経由で行う。
   - IR.21 / 二者間の設定交換 (静的): ローミング契約時に H 事業者が IR.21 (RAEX) に SEPP の
     FQDN/IP、AS 番号、IP レンジ、DNS サーバを記載して渡す。ファイアウォールの許可リストや
     IREG 試験に使うため、DNS が引けても静的情報は必ず存在する。
3. **IP → 経路 (BGP)**: 得られた IP 宛のパケットを V 事業者 → V 側 IPX → (ピアリング) →
   H 側 IPX → H 事業者 と BGP の経路表で転送する。段階 2 の DNS サーバへの到達性も同じ経路に依存する。

BGP は「どのプレフィクスへどの隣接 AS 経由で行けるか」しか教えない。H-SEPP の IP そのものは、
H 事業者自身が DNS ゾーンと IR.21 に公開したものを V 側が引くか設定するかして知る。
インターネットと同じ仕組みで、違いは (a) DNS ツリーが IPX 網内の私設ツリー、(b) 名前が
PLMN ID から導出できるので「相手の名前を知る」段階が不要、の二点。

N32-c のハンドシェイク先は上の手順で知る必要があるが、N32-f の宛先は N32-c の中で相手が
教えることもできる (TS 29.573 `SecNegotiateReqData` の `senderN32fFqdn` / `senderN32fPort`、
Rel-17)。その FQDN もやはり IPX DNS で解決する。

#### IPX 網: BGP で相互接続された私設インターネット

- 事業者 ↔ IPX 事業者: 事業者は IPX 向けプレフィクス (SEPP、UPF、DNS、DEA など) を BGP
  (小規模なら静的) で広告する。RIR 登録済みの公的 IP を使うがインターネットには広告しない
  (IR.34 は NAT なしの公的アドレスを要求)。
- IPX 事業者 ↔ IPX 事業者: GSMA が定める IPX ピアリングポイントで eBGP ピアリングし、顧客
  事業者のプレフィクスを互いに広告する。経由する IPX 事業者は最大 2 社 (IR.34)。
- 検証: 各事業者が IR.21 に AS 番号・IP レンジ・DNS・SEPP を登録し、IPX 事業者はそれで
  BGP のプレフィクスフィルタを作る。
- IPX プロキシは IP ルータではなくアプリケーションゲートウェイで、宛先はメッセージ内の
  識別子で決める:

| プロトコル | IPX プロキシ | 宛先の決め方 |
|---|---|---|
| Diameter (S6a など) | DEA/DRA | `Destination-Realm` を見て、IR.21 や NAPTR から作った realm ルーティング表で次ホップを選ぶ |
| GTP (S8/N9) | なし (IP 転送) | IP 経路表そのもの |
| N32-f PRINS (TS 33.501 13.2.4, TS 29.573) | HTTP プロキシ | Request URI の受信側 SEPP FQDN の PLMN ID から H 側 IPX / H-SEPP を選び IPX DNS で解決。送信側 SEPP には自分の IPX プロキシが設定値として与えられる。N32-c は IPX を介さず end-to-end |
| N32 TLS 直結 | なし (TCP/IP 転送) | V-SEPP が H-SEPP FQDN を IPX DNS で解決し直接到達 |
| ローミングハブ | ハブ事業者の SEPP | ハブが両 PLMN と N32 を張り、PLMN ID をキーにした転送表で振り分ける |

事業者が SEPP や DNS のホスティングを IPX 事業者に委託している場合は、委譲先が IPX 側の
サーバになり「解決したアドレスが IPX プロキシ」になる。ただしその IPX が H-SEPP の役割を
担っているので、V-SEPP から見れば相手 SEPP と変わらない。Open5GS は PRINS 未実装で TLS 直結のみ。

#### GSMA とは

GSM Association。1995 年設立の移動体通信事業者の業界団体 (本部ロンドン、MWC の主催団体)。
3GPP との役割分担:

| | 3GPP | GSMA |
|---|---|---|
| 性格 | 標準化団体 | 事業者の業界団体 |
| 決めるもの | プロトコルと手順 (TS 23/29/33.xxx) | 事業者間の運用ルール、契約の枠組み、相互接続ガイドライン |
| 例 | SEPP の機能、N32 メッセージ、FQDN 形式 (TS 23.003) | `.3gppnetwork.org` ルート DNS の運営、IPX 要件、IR.21 の様式 |

ここまでに出てきた GSMA 文書:

- **IR.21 (RAEX IR.21)**: ローミングに必要な技術情報の台帳 (PLMN ID、AS 番号、IP レンジ、DNS、SEPP の FQDN/IP)。
- **IR.34**: IPX 網の要件 (公的 IP、NAT なし、経由 IPX 最大 2 社、ピアリングポイント)。
- **IR.67**: `.3gppnetwork.org` の DNS/ENUM ガイドライン。
- **NG.113**: 5GS ローミングガイドライン (SEPP FQDN 形式、TLS/PRINS の選択、ローミングハブ)。
- **IREG**: 元は作業部会名で、転じて事業者間のローミング相互接続試験を指す。

3GPP 文書は無償公開だが、GSMA の IR/NG 系文書は多くが加盟者向け。

#### Open5GS / 今回のチャートとの対応

| 標準の要素 | Open5GS の実装 |
|---|---|
| FQDN の PLMN ID で越境判定 | `ogs_sbi_fqdn_in_vplmn()` (`lib/sbi/context.c`) |
| SEPP へ送り Target-apiRoot ヘッダ付与 | `lib/sbi/path.c`、`src/scp/sbi-path.c` |
| H-SEPP の発見 (IPX DNS / IR.21) | 設定のみ: `n32.client.sepp[].uri` のホスト名を起動時に `getaddrinfo()` で解決、`resolve:` で IP 直書き。PLMN との対応は N32-c で学習 (`sepp_node_find_by_plmn_id`) |
| H-SEPP での転送先選択 | `src/sepp/sbi-path.c` で Target-apiRoot の PLMN を見て自 PLMN なら SCP、他 PLMN なら対応 SEPP へ |
| BGP / IPX 網 | クラスタ網 (Cilium) の固定経路 |
| telescopic FQDN / PRINS / Diameter DRA | 未実装・存在しない |

---

## 12. Open5GS のコードの読み方 (AMF を起点に)

全 NF が同じ骨格 (設定読込 → SBI 初期化 → NRF 登録 → イベントループ + FSM) を持ち、NF 固有の部分は
イベントの種類と FSM の中身だけが違う。

### 12.1 ディレクトリと命名規則

| 場所 | 役割 |
|---|---|
| `src/main.c` | 全 NF 共通の `main()`。引数処理、`ogs_app_initialize()`、`app_initialize()` (NF 側)、シグナル待ち |
| `src/<nf>/` | NF 固有コード。AMF は `src/amf/` (約 34,000 行) |
| `lib/core/` | 基盤: `ogs-fsm` (状態機械)、`ogs-queue`/`ogs-pollset`/`ogs-timer` (イベントループ)、`ogs-pool`、`ogs-hash`、`ogs-list`、`ogs-log` |
| `lib/app/` | YAML 設定の読込と `global`/`logger` の解釈、`ogs_app()` コンテキスト |
| `lib/sbi/` | SBI 共通: HTTP/2 サーバ (nghttp2)・クライアント (libcurl)、NRF 登録/探索、OpenAPI メッセージの encode/decode |
| `lib/nas/5gs/` | NAS メッセージの型と encoder/decoder (生成コード) |
| `lib/ngap/`, `lib/sctp/` | NGAP ASN.1 (asn1c 生成) と SCTP ソケット |
| `lib/proto/` | 3GPP 共通型 (PLMN ID、S-NSSAI、GUTI、FQDN 生成など) |

ファイル名の接尾辞:

* `*-build.c`: 送信メッセージの組み立て (`nausf-build.c` = AUSF 向け要求)
* `*-handler.c`: 受信メッセージの解釈とコンテキスト更新 (`ngap-handler.c`)
* `*-path.c`: 送受信の経路 (`nas-path.c`、`sbi-path.c`)
* `*-sm.c`: 状態機械 (`gmm-sm.c` = UE の 5GMM 状態機械)
* `context.c/.h`: その NF のデータ構造と設定の解釈
* `n<nf>-*`: その NF が**クライアントとして**呼ぶ相手 (`nudm-handler.c` は UDM からの応答処理)、
  `namf-*` は AMF が**サーバとして**提供する Namf

### 12.2 起動シーケンス (共通 → 固有)

```
main()                                  src/main.c
 └ ogs_app_initialize()                 lib/app/ogs-init.c
    ├ ogs_core_initialize()             ログ、メモリプール、pollset、timer_mgr、event queue
    ├ YAML 読込 → logger / global        lib/app/ogs-config.c (global.max.ue → プールサイズ)
 └ app_initialize()                     src/amf/app.c
    ├ ogs_sctp_init()                   NGAP 用 SCTP
    └ amf_initialize()                  src/amf/init.c:33
       ├ amf_context_init()             AMF のプール (gnb, ran_ue, amf_ue, sess) を確保
       ├ ogs_sbi_context_parse_config(APP_NAME, "nrf", "scp")   ← 共通: amf.sbi.* を読む
       ├ amf_context_parse_config()     ← 固有: amf.ngap / guami / tai / plmn_support / access_control
       ├ amf_sbi_open()                 src/amf/sbi-path.c:26
       ├ ngap_open()                    SCTP サーバを listen (src/amf/ngap-path.c)
       └ ogs_thread_create(amf_main)    イベントループを別スレッドで開始
```

* `ogs_sbi_context_parse_config()` (`lib/sbi/context.c:224`) は全 NF 共通。引数が「`client.nrf` / `client.scp`
  を読め」という指示で、`sbi.server[]` (bind/advertise/TLS)、`sbi.client`、`default.tls`、`serving` を
  `ogs_sbi_self()` と `ogs_local_conf()` に格納する。`advertise` の名前解決 (`context.c:912-941`) もここ。
* `amf_sbi_open()`: `ogs_sbi_nf_instance_build_default()` で自分の NF プロファイルを作り、
  `ogs_sbi_nf_service_build_default()` で `namf-comm` を足し、NRF/SCP のインスタンスに `ogs_sbi_nf_fsm_init()`
  で登録 FSM を開始、`ogs_sbi_server_start_all()` で HTTP/2 サーバを起動 (受信は `OGS_EVENT_SBI_SERVER`)。

### 12.3 イベントループと FSM (全 NF 共通の心臓部)

`src/amf/init.c:125` の `amf_main()`:

```c
ogs_fsm_init(&amf_sm, amf_state_initial, amf_state_final, 0);
for (;;) {
    ogs_pollset_poll(pollset, ogs_timer_mgr_next(timer_mgr));  // ソケット I/O 待ち
    ogs_timer_mgr_expire(timer_mgr);                            // 満了タイマを発火
    while (ogs_queue_trypop(queue, &e) == OGS_OK)               // 溜まったイベントを
        ogs_fsm_dispatch(&amf_sm, e);                           // 1 つの FSM に流す
}
```

* 単一スレッドのイベント駆動。ソケットの受信コールバック (SCTP、HTTP/2) はパケットを `amf_event_t` に
  包んでキューに push するだけで、処理はこのループ内。ロックはほぼ無い。
* イベントは 2 層: 共通 (`OGS_EVENT_SBI_SERVER` / `SBI_CLIENT` / `SBI_TIMER`) と NF 固有
  (`src/amf/event.h`: `AMF_EVENT_NGAP_MESSAGE`、`NGAP_LO_ACCEPT`、`5GMM_MESSAGE`、`5GSM_MESSAGE`、各タイマ)。
* トップ FSM は `amf-sm.c:47 amf_state_operational()` 一つで、巨大な `switch (e->h.id)` = 配電盤。

| イベント | 配電先 |
|---|---|
| `OGS_EVENT_SBI_SERVER` (HTTP 要求受信) | サービス名 × リソース名 × メソッドで `SWITCH/CASE`。`namf-comm` → `namf-handler.c`、NRF 通知 → `lib/sbi/nnrf-handler.c`、SMF/UDM コールバック → `amf_namf_callback_*` |
| `OGS_EVENT_SBI_CLIENT` (HTTP 応答受信) | NRF 関連は `nf_instance->sm` か `amf_nnrf_handle_nf_discover()`。それ以外は応答に紐づく `ogs_sbi_xact_t` から `amf_ue`/`amf_sess` を取り出し、`amf_ue->sm` へ dispatch するか `amf_nsmf_pdusession_handle_*` を直接呼ぶ |
| `OGS_EVENT_SBI_TIMER` | NRF ハートビート、応答待ちタイムアウト (`xact->t_response`) |
| `AMF_EVENT_NGAP_LO_ACCEPT` / `SCTP_COMM_UP` / `CONNREFUSED` | gNB コンテキストの追加/削除、gNB FSM 初期化 |
| `AMF_EVENT_NGAP_MESSAGE` | `gnb->sm` (`ngap-sm.c`) → NGAP デコード → `ngap-handler.c` の各手続き |
| `AMF_EVENT_5GMM_MESSAGE` | NAS デコード、SUCI/GUTI で `amf_ue` を特定/生成 → `amf_ue->sm` (`gmm-sm.c`) |
| `AMF_EVENT_5GSM_MESSAGE` | UL NAS Transport 内の 5GSM ペイロードを SMF へ転送 |

`SWITCH(str) / CASE("...") / DEFAULT / END` は文字列比較マクロ (`lib/core/ogs-macros.h`)。`strcmp` の連鎖。

### 12.4 共通 SBI ライブラリの読みどころ (`lib/sbi/`)

1. **NF 登録 FSM** `nf-sm.c`: `ogs_sbi_nf_state_will_register` (NFRegister を PUT、失敗時タイマで再試行) →
   `ogs_sbi_nf_state_registered` (ハートビート PATCH、`t_no_heartbeat` で死活監視)。NRF 応答から serving PLMN や
   heartbeat_interval を取り込むのは `nnrf-handler.c:53` 付近。
2. **探索と送信** `path.c`: 入口は `ogs_sbi_discover_and_send(xact)`。既知の NF があれば
   `ogs_sbi_send_request_to_nf_instance()`、無ければ NRF 探索 (直接 or SCP 委任)。
   `ogs_sbi_send_request_to_client()` (`path.c:779`) が「SCP があれば SCP へ、宛先が他 PLMN なら SEPP へ」を判定。
3. **トランザクション** `ogs_sbi_xact_t` (`context.h:275`): どの UE/セッションの、どのサービス宛の要求を、
   どの状態で待っているかを保持。`build` 関数ポインタを持ち、探索完了後にそれで要求を組み立てる。
   応答時は xact から元の `amf_ue` と `state` を復元して FSM へ。**非同期処理の継続情報はすべて xact にある**。
4. **メッセージ** `message.c`: HTTP と OpenAPI モデル (`lib/sbi/openapi/`) の相互変換。
   `ogs_sbi_message_t` の `h.service.name` / `h.resource.component[]` / `h.method` が分岐キー。
5. **サーバ/クライアント** `nghttp2-server.c`、`client.c`: I/O 層。`client.c:561` 付近の `CURLOPT_RESOLVE`
   (`resolve:`) や接続タイマなど運用で効く設定はここ。

AMF 側のラッパが `src/amf/sbi-path.c:97 amf_ue_sbi_discover_and_send()`。ローミング時に `target-plmn-list`
を付ける処理もここで、「共通ライブラリに NF 固有の判断を注入する」典型例。

### 12.5 AMF 固有の構造 (`src/amf/context.h`)

```
amf_context_t (amf_self())        設定 + 各プール + ハッシュ (SUCI→amf_ue, GUTI→amf_ue, ...)
 ├ amf_gnb_t   (context.h:142)    SCTP 接続単位。supported TA list、gNB FSM (ngap-sm.c)
 │   └ ran_ue_t (context.h:187)   gNB 上の UE コンテキスト (RAN/AMF UE NGAP ID)。N2 接続ごとに生成
 ├ amf_ue_t    (context.h:346)    NAS 上の UE。SUPI/SUCI/GUTI、セキュリティ文脈、allowed NSSAI、
 │                                 5GMM FSM (gmm-sm.c)、ran_ue への参照 (切断で外れる)
 │   └ amf_sess_t (context.h:799) PDU セッション。PSI、S-NSSAI/DNN、SMF の sm-context URI、H-SMF 関連
```

`ran_ue_t` と `amf_ue_t` が分かれているのが重要。RRC/N2 が切れても `amf_ue` は残り (CM-IDLE)、次の
Initial UE Message で新しい `ran_ue` に `amf_ue_associate_ran_ue()` で再結合する。ログの
「Holding NG Context」「Clear NG Context」はこの付け替え。

### 12.6 UE 手続きの流れ (登録を例に)

1. `ngap-sctp.c:123 ngap_recv_handler()` が SCTP から読み、`AMF_EVENT_NGAP_MESSAGE` を push
2. `amf-sm.c:900` → `gnb->sm` (`ngap-sm.c:40`) → `ngap_handle_initial_ue_message()` (`ngap-handler.c:668`):
   `ran_ue_add`、TAI/Cell を記録、NAS PDU を `AMF_EVENT_5GMM_MESSAGE` に変換
3. `amf-sm.c:963`: NAS デコード、SUCI で `amf_ue_find_by_suci()` か `amf_ue_add()`、`amf_ue->sm` へ
4. `gmm-sm.c:83 gmm_state_de_registered`: `gmm_handle_registration_request()` で検証 (cleartext IE、TAI、
   Requested NSSAI vs plmn_support、access_control) → `OGS_FSM_TRAN(gmm_state_authentication)` し
   `amf_ue_sbi_discover_and_send(Nausf_UEAuthentication, ...)` を発行
5. 応答 → `amf-sm.c:322` → xact → `gmm_state_authentication` (`gmm-sm.c:2119`) で `nausf-handler.c` →
   Authentication Request を `nas-path.c:468` で送信
6. 以降 `gmm_state_security_mode` (2751) → `gmm_state_initial_context_setup` (3150: UDM の UECM/SDM、
   PCF の AM ポリシー、Initial Context Setup Request) → `gmm_state_registered` (898: PDU セッション要求、
   Service Request、Deregistration)

各状態関数は「`AMF_EVENT_5GMM_MESSAGE` なら NAS の種類で分岐、`OGS_EVENT_SBI_CLIENT` なら xact の `state` で
分岐、タイマなら再送か諦め」という同じ形。PDU セッションは `gmm-sm.c:1197` 付近の UL NAS Transport →
`amf_sess_add()` → `amf_sess_sbi_discover_and_send(Nsmf_PDUSession, ...)` → `nsmf-handler.c` →
`ngap-build.c` の PDU Session Resource Setup。ローミング分岐は `gmm-handler.c:1508-1584`。

### 12.7 FSM とは

FSM = Finite State Machine (有限状態機械)。「対象は常に 1 つの状態にあり、イベントが来ると現在の状態に応じて
処理し、必要なら別の状態に移る」モデル。登録手続きのような**会話**は各ステップで「次に何が来るべきか」が
変わるので、状態を名前付きで持ち、状態ごとに「このイベントならこうする」を書く。3GPP 仕様自体が状態
(5GMM-DEREGISTERED、5GMM-REGISTERED ...) で書かれているのでコードと対応しやすい。

Open5GS の実装 (`lib/core/ogs-fsm.h` / `.c`) は関数ポインタ 3 つだけ:

```c
typedef void (*ogs_fsm_handler_t)(void *sm, void *event);
typedef struct {
    ogs_fsm_handler_t init;   // 最初の状態
    ogs_fsm_handler_t fini;   // 終了時に呼ぶ関数
    ogs_fsm_handler_t state;  // 現在の状態 = 関数そのもの
} ogs_fsm_t;
```

* **状態 = 関数**。`gmm_state_authentication` のような関数が状態で、`sm->state` にそのアドレスが入る。
* `ogs_fsm_dispatch(sm, e)` は `(*sm->state)(sm, e)` を呼ぶだけ。
* 遷移は `OGS_FSM_TRAN(sm, 新状態)` (= `sm->state` への代入)。`ogs_fsm_tran()` 経由だと旧状態に
  `OGS_FSM_EXIT_SIG`、新状態に `OGS_FSM_ENTRY_SIG` の擬似イベントを配ってから切り替える。状態関数先頭の
  `case OGS_FSM_ENTRY_SIG:` は入った瞬間 (タイマ開始など)、`EXIT_SIG` は出る瞬間 (タイマ停止など) の処理。
* `OGS_FSM_CHECK(sm, 状態)` で「今この状態か」を判定。SEPP の `Assertion 'OGS_FSM_STATE(&sepp_node->sm)'`
  は「FSM 未初期化で state が NULL」の意味。

状態関数の典型形:

```c
void gmm_state_authentication(ogs_fsm_t *s, amf_event_t *e)
{
    switch (e->h.id) {
    case OGS_FSM_ENTRY_SIG:            /* 状態に入った */            break;
    case AMF_EVENT_5GMM_MESSAGE:       /* NAS が来た: 種類で分岐 */   break;
    case OGS_EVENT_SBI_CLIENT:         /* AUSF の応答: 成功なら OGS_FSM_TRAN(s, &gmm_state_security_mode) */ break;
    case AMF_EVENT_5GMM_TIMER:         /* T3560 満了: 再送 or 諦め */ break;
    }
}
```

AMF 内の FSM の階層:

| FSM | 1 インスタンスの単位 | 状態の例 | ファイル |
|---|---|---|---|
| `amf_sm` | プロセスに 1 つ | `amf_state_operational` (配電盤) | `amf-sm.c` |
| `nf_instance->sm` | NRF/SCP/相手 NF ごと | `will_register` → `registered` | `lib/sbi/nf-sm.c` |
| `gnb->sm` | SCTP 接続 (gNB) ごと | `ngap_state_operational` / `exception` | `ngap-sm.c` |
| `amf_ue->sm` | UE ごと | `de_registered` → `authentication` → `security_mode` → `initial_context_setup` → `registered`、`exception` | `gmm-sm.c` |

トップの `amf_sm` がイベントを受け、対象 (gNB や UE) を特定してその FSM に dispatch する入れ子構造。
状態関数は共有され、`amf_ue->sm.state` は UE ごとに別の値を持つので独立に進む。

### 12.8 読む順番

1. `src/main.c` → `lib/app/ogs-init.c` → `src/amf/app.c` → `src/amf/init.c`
2. `lib/core/ogs-fsm.h` と `src/amf/event.h`
3. `src/amf/amf-sm.c` を上から (配電盤の全体像)
4. `src/amf/context.h` (構造体の関係)
5. `src/amf/sbi-path.c:26-160`、`lib/sbi/nf-sm.c`、`lib/sbi/path.c:576-800`
6. `src/amf/ngap-sm.c` → `ngap-handler.c` の `ngap_handle_ng_setup_request` と `ngap_handle_initial_ue_message`
7. `src/amf/gmm-sm.c` の `gmm_state_de_registered` → `gmm_state_authentication` の順に登録手続きを追う
8. 必要に応じて `*-build.c` / `*-handler.c` のペア

コツ: 状態関数の一覧 (`grep -n "^void gmm_state_" src/amf/gmm-sm.c`) が仕様書の状態図に相当する。各状態関数内の
`OGS_FSM_TRAN` を探すと遷移図が描ける。`logger.level: debug` で分岐がログに出る。

---

## 14. 4G (EPC) を同居させる: MME/HSS/SGW/PCRF、srsRAN_4G、S6a/S8 ローミング

`helm/open5gs` に `epc.enabled: true`、`srsran.enabled: true` を足すと、5GC と同じクラスタに
EPC と srsRAN_4G の eNB/UE が載る。`helm/open5gs-mvno` 側は HSS と PCRF を持ち、MNO の MME から
S6a、MNO の SGW-C/SGW-U から S8 で到達される (4G 版の Home-Routed ローミング)。

### 14.1 構成要素の対応

| 4G NF | 5GC での対応 | チャートでの実体 | 主なインターフェース |
|---|---|---|---|
| MME | AMF (+SMF の一部) | `open5gs-mme` (+ headless `open5gs-mme-s1ap`) | S1AP/SCTP 36412、S11 GTP-C 2123、S6a Diameter 3868 |
| HSS | UDM + AUSF + UDR | `open5gs-hss` / `mvno-hss` | S6a、MongoDB (5GC と同じ DB) |
| SGW-C / SGW-U | なし (UPF に統合) | `open5gs-sgwc` / `open5gs-sgwu` | S11、S5/S8-C、Sxa PFCP、S1-U/S5-U GTP-U |
| PGW-C / PGW-U | SMF / UPF | **既存の `smf-<dnn>...` / `upf-<dnn>...` が兼任** | S5/S8-C、Gx、Sxb、S5-U |
| PCRF | PCF | `open5gs-pcrf` / `mvno-pcrf` | Gx、MongoDB |
| eNB + UE | UERANSIM gNB/UE | `open5gs-lte-<name>` (srsenb + srsue を 1 コンテナ) | S1AP、S1-U、ZMQ (localhost) |

- どの SMF/UPF が PGW になるか: **DNN 名ごとに `dnns[]` の最初のエントリ** (例: `internet` →
  `smf-internet-sst1`)。4G には S-NSSAI が無いので APN 名でしか選べない。その SMF にだけ
  `gtpc.server` と `freeDiameter` (Gx) が入り、MME の `gtpc.client.smf[]` に `apn: [internet]` で
  登録される。`dnns[].epc: false` で除外できる。
- 加入者は 5G と共有。HSS は `slice[0].session[]` を APN リストとして読む (`src/hss/hss-s6a-path.c`)
  ので、`subscribers[].dnn` がそのまま APN になる。

### 14.2 Diameter (S6a / Gx) の Identity と Realm

- **Identity (Origin-Host / Destination-Host)**: ノード 1 台の固有名。相手の CER/CEA で名乗る名前と
  `ConnectPeer` の名前が一致しないと切断される。3GPP では `<node>.epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org`
  (TS 23.003 19.4)。
- **Realm (Origin-Realm / Destination-Realm)**: 管理ドメイン。1 PLMN に 1 つで
  `epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org` (TS 23.003 19.2)。Diameter のルーティングは IP ではなく
  Realm 単位 (DRA の realm ルーティング表)。
- チャートでの決め: **Identity = Service の FQDN** (`mvno-hss.mvno.svc.cluster.local` など)、
  **Realm = 3GPP 形式**。freeDiameter は `ConnectTo` を省略すると Identity を DNS で解決するので、
  クラスタ DNS でそのまま引け、固定 ClusterIP も hostAliases も要らない。`ListenOn`/`ConnectTo` は
  IP リテラル限定なので `ListenOn = "__POD_IP__"`。
- `No_SCTP;` で TCP のみ。ClusterIP Service 越しに SCTP を通す必要をなくすため。
- 着信側 (HSS/PCRF) は `ConnectPeer` を持たず、`acl_wl.fdx` の許可リスト
  (`ALLOW_OLD *.<namespace>.svc.cluster.local` + `epc.diameter.allowedPeers`) で未知のピアを受け入れる。
  freeDiameter は既定で未登録ピアからの接続を拒否するため。
- MME の HSS 選択は `hss_map` (IMSI の先頭 PLMN で一致、`src/mme/mme-context.c`)。`realm`/`host` は
  **`plmn_id:` の中に**書く (サンプルのコメントと違い、兄弟キーだと無視される)。一致しない IMSI は
  自 Realm 宛て。
- fdx 拡張のパスはイメージ内で `find /usr/local/lib -name dict_nasreq.fdx` して `__FD_LIBDIR__` を置換
  (全 NF 共通の `nfCommand` が `/config/*` を `/tmp/` にコピーする際に行う)。

### 14.3 4G ローミング (S6a + S8 Home Routed) のルート

```
srsue(99971...) == ZMQ == srsenb ──S1AP──▶ open5gs-mme ──S6a (TCP)──▶ mvno-hss   (hss_map: realm epc.mnc071..., host mvno-hss...)
                                             │  ULA: APN internet, PGW = 192.96.0.54 (session.smf.ipv4)
                                             ▼ S11
                                       open5gs-sgwc ──S8-C (UDP 2123)──▶ 192.96.0.54 (mvno-smf-internet Service) ──Gx──▶ mvno-pcrf
                                             │ Sxa                                   │ Sxb
                                       open5gs-sgwu ════ S8-U GTP-U (Pod IP 同士) ════ mvno-upf-internet ──ogstun/NAT──▶ 外部
```

- **PGW の決め方**: Open5GS の MME には PLMN ベースの PGW 選択が無い (`src/mme/mme-s11-build.c`:
  HSS 提供アドレス → DNS (serving PLMN 固定) → `gtpc.client.smf[]` の apn/tac/e_cell_id → 先頭)。
  そこで H-HSS が加入者データに `slice[0].session[].smf.ipv4` を持ち、ULA の MIP6-Agent-Info として
  MME に渡す (チャートの `epc.pgwInHss: true` が subscribers Job で `dnns[].clusterIP` を書き込む)。
  5G のコードパスはこのフィールドを読まないので 5G 加入者と共存できる。
- SGW-C は最初の Create Session を Service の ClusterIP:2123 に送り、応答の F-TEID (SMF の Pod IP)
  以降は Pod IP に直接送る (PFCP の SMF→UPF と同じ挙動)。
- S8-U は SGW-U Pod と H-UPF Pod の間の GTP-U で、5G の N9 と同じく namespace をまたいだ Pod 間通信。
- MME の `access_control` は自 PLMN と `roaming.peers[]` を許可。HSS は Visited-PLMN-Id を検査しない
  (KASME 導出に使うのみ)。
- 4G 用の MVNO 加入者は `999710000000002` (UERANSIM の ue4 と IMSI を分ける)。

### 14.4 srsRAN_4G (ZMQ) を Kubernetes に載せる際の制約

- ZMQ の仮想無線は **eNB:UE = 1:1** のみ (REQ/REP のロックステップ)。UE をデタッチしたら eNB も
  再起動が必要。→ `srsran.ues[]` 1 エントリ = 1 Pod、1 コンテナで `srsenb` と `srsue` を両方起動し、
  どちらかが死んだらコンテナごと終了して再起動する。
- `mme_addr` と bind アドレスは **IP リテラル限定** (`inet_pton` のみ)。entrypoint が headless
  `mme-s1ap` を `getent hosts` で引いて `__MME_IP__` を置換し、`gtp_bind_addr`/`s1c_bind_addr` は Pod IP。
  MME Pod が入れ替わると IP が変わるため、liveness probe (`/proc/net/sctp/assocs` に関連付けが無い、
  または `tun_srsue` にアドレスが無い) で Pod を作り直す。
- `base_srate` は PHY レートの整数倍 (25 PRB なら 5.76e6)。既定の 23.04e6 より CPU が軽い。
  1 ペアでおよそ 1〜2 コア。
- srsue は `tun_srsue` を作るが**デフォルトルートを入れない** (`gw.cc` に `SIOCADDRT` が無い)。
  entrypoint が UE アドレスを検出したら `ip rule from <ip> table 100` と `oif tun_srsue` の
  ルールで table 100 (default dev tun_srsue) に流す。これで `ping -I tun_srsue 8.8.8.8` が通る。
- srsue の PLMN 選択 (`nas::select_plmn()`) は HPLMN が見つからなければ**最初に見つけた PLMN に
  接続する** ("Could not find Home PLMN Id=..., trying to connect to PLMN Id=...")。UERANSIM と違い
  ローミング UE 用のパッチは不要。
- 設定ファイルは `enb.conf`/`rr.conf`/`sib.conf`/`rb.conf`/`ue.conf`。`sib.conf` と `rb.conf` は
  srsRAN の example をそのまま `helm/open5gs/files/srsran/` に置き `.Files.Get` で埋め込む。
- イメージは `docker/srsran/Dockerfile` (release_25_10、`-DENABLE_SRSEPC=OFF -DAUTO_DETECT_ISA=OFF`、
  ZMQ 有効) を GHCR ワークフローで amd64 ビルド。

### 14.5 確認コマンド

```bash
kubectl -n open5gs logs deploy/open5gs-mme | grep -i "s1-setup\|attach"
kubectl -n open5gs logs deploy/open5gs-lte-lte1 | grep -i "attach\|IP:"   # [ue] Network attach successful. IP: 10.45.x.x
UE=$(kubectl -n open5gs get pod -l app.kubernetes.io/component=lte-lte1 -o jsonpath='{.items[0].metadata.name}')
kubectl -n open5gs exec $UE -- ping -I tun_srsue -c 3 8.8.8.8
# ローミング (lte4 = 999710000000002)
kubectl -n mvno logs deploy/mvno-hss | grep 999710000000002
kubectl -n mvno logs deploy/mvno-smf-internet | grep 999710000000002         # IPv4[10.50.x.x]
```

### 14.6 MME の PGW 選択と LBO / HR の決まり方

Open5GS の MME に「PLMN ベースの PGW 選択が無い」のは、LBO ができないという意味ではない。
選択順 (`src/mme/mme-s11-build.c:123-168`) は次のとおりで、**何も指示しなければ訪問先 PGW
(= LBO) に落ちる**。できないのは「IMSI の H-PLMN を見て PGW を切り替える」ことの方。

| 優先 | 情報源 | キー | ローミングでの意味 |
|---|---|---|---|
| 1 | HSS の ULA (MIP6-Agent-Info → `session.smf.ipv4`) | 加入者 × APN | H-HSS がアドレスを渡せば **HR**。渡さなければ下へ |
| 2 | DNS (S-NAPTR、`<APN-NI>.apn.epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org`) | APN × **serving PLMN** | 自網ゾーンしか引かない (`src/mme/mme-dns.c` の LIMITATION コメント) → V-PGW = **LBO** |
| 3 | 静的 `gtpc.client.smf[]` | APN / TAC / eCellID | V-PGW = **LBO** |
| 4 | 先頭エントリ | なし | V-PGW = **LBO** |

* ラボで lte4 を LBO にしたければ MVNO 側 `epc.pgwInHss: false` にすれば MME は自網 SMF を選ぶ。
  ただし Open5GS に S9 (V-PCRF ↔ H-PCRF) は無く、V-PCRF は自分の MongoDB で IMSI+APN を引くため、
  **その IMSI を MNO 側 DB にも入れておかないと Gx CCA が失敗し Create Session が拒否される**。
* HR か LBO かを決める軸は H-PLMN (IMSI) または加入者であり、V-PLMN の MCC/MNC (= MME 自身の
  serving PLMN) ではない。Open5GS ではこれを **H-HSS の加入者データ (APN ごとの `smf.ipv4` の有無)**
  で表現する。3GPP のモデル (HSS が PDN-GW-Allocation-Type / MIP6-Agent-Info で HR を指示、
  VPLMN-Dynamic-Address-Allowed で LBO 可否を指示) に近い分担。
* Open5GS HSS は VPLMN-Dynamic-Address-Allowed を常に ALLOWED で送り、MME はこの AVP を読まない
  (`src/mme` に参照なし)。「H-PLMN が LBO を禁止する」制御は効かず、HR になるかは
  「HSS が PGW アドレスを返したか」だけで決まる。

### 14.7 一般的な MME の DNS による PGW 選択 (TS 23.003 / 29.303 / 23.401)

APN-FQDN は `<APN-NI>.apn.epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org`。先頭が APN-NI (`internet`)、
`mnc<MNC>.mcc<MCC>` の部分が APN-OI に相当する。どの PLMN の MCC/MNC を入れるかは HR / LBO で変わる。

| ケース | APN-OI に入れる PLMN | 引く DNS | NAPTR サービス |
|---|---|---|---|
| LBO | serving PLMN (自網) | 自網 DNS | `x-3gpp-pgw:x-s5-gtp` |
| HR | home PLMN (IMSI から導出、または HSS の APN-OI-Replacement) | IPX 経由の GSMA ルート DNS | `x-3gpp-pgw:x-s8-gtp` |

* LBO の FQDN は APN-NI が主キーなので、APN ごとに別 PGW、order/preference で優先度、
  `topon.` ラベルで SGW に近い PGW、といった制御が DNS だけでできる。Open5GS の DNS 解決と
  `gtpc.client.smf[].apn` も同じ役割。
* DNS で決まるのは「APN → どの PGW か」まで。HR にするか LBO にするかは HSS の
  VPLMN-Dynamic-Address-Allowed と MME のローカルポリシーで先に決め、その結果でどちらの FQDN を
  組むかが変わる。FQDN に IMSI は入らないので、同じ APN で H-PLMN ごとに LBO 先を変えるのも
  DNS ではなく MME ポリシーの仕事。

### 14.8 「S6a」はインターフェース名、プロトコルは Diameter

S6a は 3GPP のリファレンスポイント (MME ↔ HSS) の名前で、その上を流れるプロトコルが Diameter
(TS 29.272)。同時に **Diameter の「アプリケーション」の名前でもある**: Diameter は基底プロトコル
(RFC 6733) の上にアプリケーションを定義する作りで、S6a には Application-Id 16777251、Gx には
16777238、Rx には 16777236 が割り当てられている。CER/CEA でこの ID を交換して「S6a を話せる」ことを
確認し、ルーティングも Destination-Realm + Application-Id で行う。

| インターフェース | 両端 | プロトコル |
|---|---|---|
| S6a / S6d | MME / SGSN ↔ HSS | Diameter |
| Gx / Rx / S9 | PGW-C ↔ PCRF / P-CSCF ↔ PCRF / V-PCRF ↔ H-PCRF | Diameter |
| Cx / Sh | CSCF, AS ↔ HSS | Diameter |
| S1-MME | eNB ↔ MME | S1AP over SCTP |
| S11 / S5 / S8 | MME ↔ SGW-C / SGW ↔ PGW | GTPv2-C (+ GTP-U) |

Open5GS でも二層が見える: freeDiameter 本体が基底プロトコル (ピア接続、CER/CEA、DWR/DWA、
ルーティング)、`dict_*.fdx` 拡張と `lib/diameter/s6a` などのライブラリがアプリケーション辞書。

### 14.9 freeDiameter configuration file

Diameter ノード 1 つ分の「自分は誰で、どこで待ち受け、誰とつながり、どの拡張を読むか」。
Open5GS では MME / HSS / PCRF / SMF (PGW-C) が各 1 つ持ち、NF の YAML の `freeDiameter:` キーで
パスを指す。同梱サンプルは `configs/freeDiameter/*.conf.in`、チャートが生成するものは
`_helpers.tpl` の `open5gs.fdConf`。書式は `Key = value;`、`#` はコメント。

| 区分 | ディレクティブ | 意味 |
|---|---|---|
| 自分の名前 | `Identity` | Diameter Identity。CER の Origin-Host になり、相手の `ConnectPeer` 名と一致が必要 |
| | `Realm` | Origin-Realm。省略時は Identity の最初のドット以降 |
| 待ち受け | `ListenOn` | bind する IP。**IP リテラルのみ** |
| | `Port` / `SecPort` | 平文 3868 / TLS 5868。`SecPort = 0` で TLS 待ち受けを無効化 |
| | `No_SCTP` / `No_TCP` / `Prefer_TCP` / `No_IPv6` | トランスポート選択 (既定は SCTP 優先) |
| TLS | `TLS_Cred` / `TLS_CA` | 証明書+鍵と CA。**CN が Identity と一致しないと起動失敗** |
| タイマー | `TcTimer` / `TwTimer` | 再接続間隔 / DWR 間隔 (既定 30 秒) |
| 振る舞い | `NoRelay` | 自分宛でないメッセージを中継しない (DRA でなければ付ける) |
| 拡張 | `LoadExtension = "x.fdx" [: "conf"]` | `dict_*` (辞書)、`dbg_*` (フック)、`acl_*` / `rt_*` (ACL・ルーティング) |
| ピア | `ConnectPeer = "<identity>" { ConnectTo; Port; No_TLS; No_SCTP; Realm; ... };` | 自分から接続しに行く相手 |

* freeDiameter は `ConnectPeer` に書いたピアにだけ自分から接続し、**着信は既知のピアからしか受けない**。
  相手の Identity は CER の Origin-Host で照合。`ConnectTo` が無ければ Identity を DNS で引く。
  片側 (クライアント側) だけに `ConnectPeer` を書き、サーバー側は `acl_wl.fdx` で
  `ALLOW_IPSEC *.open5gs.svc.cluster.local` のように許可するのがチャートの構成。
* S6a / Gx 自体の辞書は `.fdx` ではなく Open5GS ライブラリがプロセス内で登録するので設定には出ない。
* チャート版と同梱版の差: Identity = Service FQDN、Realm = `epc.mnc<MNC>.mcc<MCC>.3gppnetwork.org`、
  `ListenOn = __POD_IP__` (起動時置換)、`No_SCTP` (ClusterIP Service を通すため TCP)、
  `SecPort = 0` (同梱証明書の CN が `mme.localdomain` 固定で Identity と合わない)、
  `ConnectPeer` に `ConnectTo` を書かず DNS に任せる。YAML インラインの `freeDiameter:` は
  `no_sctp` や `acl_wl` を表現できないので `.conf` を ConfigMap で配る。

### 14.10 MVNO 構成での Diameter ピア一覧 (レンダリング結果)

ConnectPeer を持つのは「接続しに行く側」の MME と SMF だけ。HSS / PCRF は `acl_wl` で受ける側。

MNO (`open5gs`、Realm `epc.mnc070.mcc999.3gppnetwork.org`):

| モジュール | ConnectPeer | 着信許可 (acl_wl) |
|---|---|---|
| open5gs-mme | `open5gs-hss.open5gs.svc.cluster.local` (自網 S6a)、`mvno-hss.mvno.svc.cluster.local` (ローマー用、`roaming.peers[].epc.hss`) | なし |
| open5gs-hss / open5gs-pcrf | なし | `*.open5gs.svc.cluster.local` |
| open5gs-smf-internet-sst1 / open5gs-smf-ims | `open5gs-pcrf.open5gs.svc.cluster.local` (Gx) | なし |

MVNO (`mvno`、Realm `epc.mnc071.mcc999.3gppnetwork.org`):

| モジュール | ConnectPeer | 着信許可 (acl_wl) |
|---|---|---|
| mvno-hss / mvno-pcrf | なし | `*.mvno.svc.cluster.local`、`*.open5gs.svc.cluster.local` (訪問先 MME 用、`epc.diameter.allowedPeers`) |
| mvno-smf-internet (PGW-C) | `mvno-pcrf.mvno.svc.cluster.local` (Gx) | なし |

* **PLMN をまたぐ Diameter は MME → mvno-hss の S6a だけ**。S8 で H-PGW に来たセッションの Gx は
  H-PLMN 内で閉じる。MNO PCRF と MVNO の間に接続は無い (S9 は Open5GS に無く、HR では不要)。
* MME は 2 つの HSS と常時接続を張り、宛先は `hss_map` (IMSI 先頭 99971 → `epc.mnc071…` /
  `mvno-hss…`) で選ぶ。ConnectPeer は「接続を維持する相手」、宛先選択は別レイヤー。
* mvno-pcrf の `*.open5gs…` 許可は現状使われていない (狭めるなら HSS だけで十分)。

### 14.11 実網で PLMN 境界を越える接続 (EPC)

HR のデータローミング最小構成なら **S6a と S8 (+ DNS)** だけ。S9 は Diameter、GTP が境界を越えるのは
S8 (S9 と S8 を混同しないこと)。

| 境界を越える接続 | プロトコル | いつ必要か |
|---|---|---|
| S6a (MME ↔ H-HSS)、S6d / Gr (SGSN ↔ HSS/HLR) | Diameter / MAP | 常に (3G/2G は提供する場合) |
| S8 (V-SGW ↔ H-PGW)、Gp (V-SGSN ↔ H-GGSN) | GTPv2-C + GTP-U / GTPv1 | HR のみ |
| S9 (V-PCRF ↔ H-PCRF) | Diameter | **LBO のみ**が原則 |
| DNS (MME → GSMA ルート DNS → H-PLMN DNS) | DNS | HR で H-PGW を S-NAPTR で探すとき |
| SIP / RTP (II-NNI) | SIP, RTP | VoLTE を LBO で組む場合。S8HR なら IMS は S8 の中に閉じる |
| SMS (SGs → MSC ↔ HLR/HSS、または SGd MME ↔ H-SMSC) | MAP / Diameter | SMS を提供する場合 |
| S13 (MME ↔ H-EIR)、SLg/SLh、Lr | Diameter / MAP | 端末チェック、位置情報 (任意) |
| TAP / BCE (課金レコード交換) | ファイル転送 (DCH) | オフラインで事後交換 |

* 越えないもの: S1 / S11 / S5 / Gx (HR では H-PLMN 内) / Gy / Gz。S10 による PLMN 間ハンドオーバーは
  仕様上可能だが商用ではほぼ使われず、PLMN 間の移動は再 Attach。
* 全部 IPX (GRX) 上を流れ、Diameter は DRA / DEA、GTP は Border Gateway、SIP は IBCF で境界を通す。
  5GC では SEPP (N32) と UPF 間の N9 が同じ役割。
* 今回のラボは S6a だけ Diameter で越え、S8 の宛先を HSS の加入者データで渡しているので DNS を省いた形。

---

## 15. 参考

* Quickstart (tun、NAT、ファイアウォール、加入者登録):
  https://open5gs.org/open5gs/docs/guide/01-quickstart/
* 全オプションのコメント付きサンプル設定: `configs/open5gs/amf.yaml.in`、
  `smf.yaml.in`、`upf.yaml.in`、`nrf.yaml.in`、`scp.yaml.in`
* ローカル実行用の Docker compose 構成: `docker/docker-compose.yml`
* build イメージが使う tun/経路設定スクリプト: `docker/build/setup.sh`
* マルチ VM の参考構成 (Qiita): https://qiita.com/s5uishida/items/c22f82aea5614bb4c2d7
* その設定の全文: https://github.com/s5uishida/open5gs_5gc_ueransim_sample_config
* UERANSIM: https://github.com/aligungr/UERANSIM/wiki
