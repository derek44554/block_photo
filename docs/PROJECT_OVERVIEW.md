# BlockPhoto 项目文档

> 本文档面向开发者和 AI，完整描述项目结构、功能逻辑和操作方式，读完即可上手。

---

## 一、项目简介

**BlockPhoto** 是一款基于 Block 去中心化网络的加密相册 Flutter 应用。

- 照片加密后上传至 IPFS，只有持有密钥的用户才能访问
- 通过 Block 节点管理照片元数据（Block 是一种去中心化数据协议）
- 支持 Android / iOS 双平台
- 版本：`0.1.0+1`，作者：Derek X
- GitHub：https://github.com/derek44554/block_photo
- 官网：https://blocklink.cc

---

## 二、技术栈

| 类别 | 技术 |
|------|------|
| 框架 | Flutter (Dart SDK ^3.9.2) |
| 状态管理 | Provider ^6.1.2 |
| 本地存储 | shared_preferences ^2.3.2 |
| 加密 | cryptography ^2.7.0（AES-GCM-256） |
| Block 网络 SDK | block_flutter（私有 Git 依赖，v0.1.0） |
| HTTP | http ^1.2.0 |
| 图片选择 | image_picker ^1.1.2 |
| EXIF 解析 | exif ^3.3.0 |
| 权限管理 | permission_handler ^12.0.1 |
| 路径工具 | path ^1.9.0 + path_provider ^2.1.5 |
| 外部链接 | url_launcher ^6.3.1 |
| UI 风格 | Material Design 3，主色 #1A73E8 |

---

## 三、项目目录结构

```
block_photo/
├── lib/
│   ├── main.dart                    # 入口，初始化 Provider，启动 App
│   ├── models/
│   │   └── photo_collection.dart    # 数据模型：PhotoCollection、PhotoItem
│   ├── providers/
│   │   ├── connection_provider.dart # 节点连接状态管理
│   │   └── photo_provider.dart      # 相册集合状态管理
│   ├── screens/
│   │   ├── gallery_screen.dart      # 主界面：照片网格
│   │   ├── photo_detail_screen.dart # 全屏查看照片
│   │   ├── upload_screen.dart       # 上传照片
│   │   ├── setup_screen.dart        # 节点配置
│   │   ├── settings_screen.dart     # 设置入口
│   │   └── about_screen.dart        # 关于页面
│   ├── services/
│   │   ├── block_service.dart       # Block 网络操作（查询/缓存/保存）
│   │   ├── upload_service.dart      # 上传流程（EXIF 提取、加密、IPFS 上传）
│   │   └── image_service.dart       # 图片加载（多级缓存 + 解密）
│   ├── widgets/
│   │   └── photo_grid_item.dart     # 网格单元格 Widget
│   └── theme/
│       └── app_theme.dart           # 全局主题（亮色/暗色）
├── android/                         # Android 原生配置
├── ios/                             # iOS 原生配置
├── pubspec.yaml                     # 依赖声明
└── docs/                            # 项目文档（本文件所在目录）
```

---

## 四、核心概念

### Block 网络
Block 是一个去中心化数据协议。每条数据称为一个 **Block**，有唯一标识 **BID**（Block ID）。照片元数据以 Block 形式存储在节点上，文件内容存储在 IPFS 上。

### 集合（Collection）
集合是一个特殊的 Block，用于组织照片。照片通过 `link` 字段关联到一个或多个集合。集合支持 `link_tag` 标签，用于在集合内进一步分类。

### 节点（Node）
用户需要配置一个 Block 节点地址（HTTP）和对应的 AES 密钥（Base64）。节点负责存储 Block 数据，IPFS 端点负责存储文件内容。

### 加密（PPE-001）
上传时可选择加密。加密算法为 AES-GCM-256，密钥随机生成并存储在 Block 的 `ipfs.encryption` 字段中。解密在 Dart Isolate 中执行，不阻塞 UI。

---

## 五、数据模型

### PhotoCollection
```dart
class PhotoCollection {
  final String bid;          // Block ID，唯一标识
  final bool isAlbum;        // 是否作为相册显示
  final bool isDefault;      // 是否为默认相册（主页展示）
  String? get title;         // 集合名称（来自 block['name']）
  List<String> get linkTags; // 可用的 tag 过滤列表
}
```

### PhotoItem
```dart
class PhotoItem {
  final String cid;            // IPFS Content ID
  final String bid;            // Block ID
  final String title;          // 照片名称
  final String time;           // 格式化时间字符串
  final String? ext;           // 文件扩展名（.jpg/.png 等）
  final String? encryptionAlgo; // 加密算法（PPE-001 或 null）
  final String? encryptionKey;  // 十六进制加密密钥
  bool get isEncrypted;        // 是否加密
  String get heroTag;          // Hero 动画 tag
}
```

---

## 六、各模块详解

### 1. main.dart — 应用入口

启动时并行初始化两个 Provider：
- `ConnectionProvider.load()` — 从 SharedPreferences 加载节点配置，并后台刷新节点信息
- `PhotoProvider.load()` — 从 SharedPreferences 加载集合列表

然后用 `MultiProvider` 包裹整个应用，根屏幕为 `GalleryScreen`。

---

### 2. ConnectionProvider — 节点连接管理

**存储键：**
- `block_connections`：节点列表（JSON 数组）
- `block_active_index`：当前激活节点索引
- `block_ipfs_endpoint`：IPFS 端点地址

**主要方法：**
- `load()` — 加载并后台刷新所有节点的 nodeData（获取节点 sender BID）
- `addConnection(connection)` — 添加节点，第一个节点自动设为激活
- `removeConnection(index)` — 删除节点
- `setActive(index)` — 切换激活节点
- `setIpfsEndpoint(endpoint)` — 设置 IPFS 地址

**关键属性：**
- `activeConnection` — 当前激活的节点（`ConnectionModel`）
- `hasActiveConnection` — 是否有可用节点
- `ipfsEndpoint` — IPFS 端点地址

---

### 3. PhotoProvider — 集合状态管理

**存储键：** `photo_collections`（JSON 数组）

**主要方法：**
- `load()` — 从本地加载集合（使用 Isolate 解析 JSON）
- `addCollection(collection)` — 添加或更新集合（按 bid 去重）
- `removeCollection(bid)` — 删除集合
- `toggleAlbum(bid, isAlbum)` — 切换是否作为相册
- `toggleDefault(bid, isDefault)` — 切换是否为默认相册
- `refreshCollections(fetchBlock)` — 从网络刷新集合数据

**关键属性：**
- `albumCollections` — 用于主页展示的集合列表（优先返回 isDefault 的，否则返回 isAlbum 的）

---

### 4. BlockService — Block 网络操作

依赖 `block_flutter` SDK 的 `BlockApi`。

**主要方法：**

| 方法 | 说明 |
|------|------|
| `syncCollectionBids({collectionBids, tag})` | 同步集合内所有照片 BID，缺失的批量拉取（每批 20 条）并写入 BlockCache |
| `getLocalBlocks({bids, page, limit})` | 从本地 BlockCache 分页读取 Block |
| `getPhotosByCollections({collectionBids, page, limit})` | 直接从网络分页拉取照片（不走缓存） |
| `getBlock(bid)` | 获取单个 Block（先查缓存，缓存未命中则请求网络） |
| `fetchBlock(bid)` | 强制从网络获取最新 Block 并更新缓存 |
| `fetchCollectionBlock(bid)` | 获取集合 Block 最新数据（不走缓存，用于刷新集合信息） |
| `saveBlock(data)` | 保存 Block 到网络 |
| `getLinkedCollectionBids(bid)` | 获取照片关联的所有集合 BID |
| `getLinksByMainWithTag({collectionBid, tag, page, limit})` | 按 tag 过滤分页拉取照片 |

**文件 Block 判断条件：**
- `model` 字段 == `c4238dd0d3d95db7b473adb449f6d282`
- `ipfs` 字段非空且包含 `cid`

---

### 5. UploadService — 上传流程

**上传步骤（`uploadPhoto` 方法）：**
1. 读取文件字节（优先使用传入的 bytes，保留完整 EXIF）
2. 调用 `extractMetaFromBytes` 提取 EXIF 元数据（时间、GPS、文件名）
3. 上传到 IPFS（`/ipfs/ipfs/upload`），可选 AES-GCM 加密
4. 缓存预览图到内存
5. 生成 BID（`generateBidV2(nodeBid)`）
6. 构建 Block 数据并调用 `BlockApi.saveBlock` 保存

**Block 数据结构：**
```json
{
  "bid": "生成的 BID",
  "node_bid": "节点 sender BID",
  "model": "c4238dd0d3d95db7b473adb449f6d282",
  "name": "照片名称",
  "intro": "描述",
  "tag": ["标签1", "标签2"],
  "link": ["集合BID1", "集合BID2"],
  "permission_level": 0,
  "ipfs": {
    "cid": "IPFS CID",
    "ext": ".jpg",
    "encryption": { "algo": "PPE-001", "key": "hex密钥" }
  },
  "add_time": "2024-01-01T00:00:00+08:00",
  "gps": { "lat": 39.9, "lon": 116.4 }
}
```

**时间提取优先级：** EXIF DateTimeOriginal → XFile.lastModified → 文件系统时间 → 当前时间

---

### 6. ImageService — 图片加载与缓存

**三级缓存策略：**
1. 内存缓存（`ImageCacheHelper.getMemoryImage`）
2. 磁盘缓存（`ImageCacheHelper.getCachedImage`）
3. 网络下载（HTTP GET `{ipfsEndpoint}/{cid}`）

**图片变体（ImageVariant）：** thumb / small / medium / original

下载后自动生成缩放变体并写入内存和磁盘缓存。

**解密：** 在 Dart Isolate 中执行，支持 nonce 长度 12/16 字节，MAC 位置可在头部或尾部，密钥支持 Hex 和 Base64 编码。

**并发去重：** 同一 `variant::cid` 的并发请求只发起一次网络请求，其余等待同一个 Future。

---

## 七、各页面说明

### GalleryScreen（主页）

- 照片网格，列数根据屏幕宽度动态计算
- 无限滚动分页（每页 40 张）
- 右侧抽屉：集合列表 + tag 过滤 + 添加集合 + 设置入口
- 左滑打开抽屉，下滑查看照片信息
- 后台同步：首次进入时同步集合内所有 BID 并缓存，切换集合时复用缓存
- 预加载：滚动时提前加载可见区域后方 12 张图片
- 右上角：同步进度指示器 + 上传按钮

**集合切换逻辑：**
- 选中某集合 → 展示该集合照片
- 未选中（"全部"）→ 展示所有 `albumCollections` 的照片
- 选中 tag → 在当前集合内按 tag 过滤

---

### PhotoDetailScreen（全屏查看）

- PageView 左右翻页
- 底部缩略图条快速跳转
- 捏合缩放（InteractiveViewer）
- 下滑关闭（拖拽超过 60px 或速度超过 600px/s）
- 上滑显示照片信息面板
- 点击切换 UI 显示/隐藏
- 每次翻页后台拉取最新 Block 数据

---

### UploadScreen（上传）

- 从相册选择图片（Android 自动请求 ACCESS_MEDIA_LOCATION 权限）
- 显示提取到的时间和 GPS 信息
- 填写名称、描述、标签
- 选择关联集合（多选）
- 权限等级选择（0-4 级）
- 加密开关（默认开启）
- 实时显示上传状态

---

### SetupScreen（节点设置）

- 配置 IPFS 端点地址（独立保存）
- 添加节点：名称 + 地址（http://...）+ AES 密钥（Base64）
- 点击"测试并保存"：先调用 `NodeApi.getSignature()` 验证连接，成功后保存
- 已配置节点列表：显示连接状态，支持切换和删除

---

### SettingsScreen / AboutScreen

- SettingsScreen：入口页，跳转节点设置和关于页
- AboutScreen：显示版本、作者、官网/GitHub/隐私政策链接

---

## 八、关键流程图

### 首次使用流程
```
启动 App
  → 无节点配置
  → 进入 GalleryScreen（空状态）
  → 打开右侧抽屉 → 设置 → 节点设置
  → 填写节点地址 + AES 密钥 + IPFS 端点
  → 测试并保存
  → 返回主页，添加集合（输入集合 BID）
  → 照片加载显示
```

### 照片加载流程
```
GalleryScreen 初始化
  → 读取 albumCollections（本地缓存）
  → syncCollectionBids：从网络拉取所有 BID，写入 BlockCache
  → getLocalBlocks：从 BlockCache 分页读取，构建 PhotoItem 列表
  → PhotoGridItem 渲染：ImageService.loadImage（三级缓存）
  → 滚动到底部 → 加载下一页
```

### 上传流程
```
UploadScreen
  → 选择图片 → 提取 EXIF（时间/GPS）
  → 填写元数据 → 选择集合 → 点击上传
  → UploadService.uploadPhoto
      → 加密文件（AES-GCM，Isolate）
      → POST /ipfs/ipfs/upload → 获取 CID
      → 构建 Block 数据
      → BlockApi.saveBlock → 保存到节点
  → 返回主页，刷新
```

---

## 九、本地数据持久化

| 数据 | 存储方式 | 键名 |
|------|----------|------|
| 节点连接列表 | SharedPreferences（JSON 数组） | `block_connections` |
| 当前激活节点索引 | SharedPreferences（int） | `block_active_index` |
| IPFS 端点地址 | SharedPreferences（string） | `block_ipfs_endpoint` |
| 集合列表 | SharedPreferences（JSON 数组） | `photo_collections` |
| Block 元数据 | BlockCache（SQLite，来自 block_flutter） | — |
| 图片文件 | 磁盘缓存（App 缓存目录） | 按 CID + variant 命名 |
| 图片内存缓存 | 内存（Map，来自 block_flutter） | — |

---

## 十、开发与构建

### 环境要求
- Flutter SDK（Dart ^3.9.2）
- Android Studio 或 Xcode
- 可访问的 Block 节点（自建或公共节点）
- 可访问的 IPFS 网关

### 安装依赖
```bash
flutter pub get
```

### 运行
```bash
# Android
flutter run

# iOS
flutter run -d ios
```

### 构建
```bash
# Android APK
flutter build apk --release

# iOS
flutter build ios --release
```

### 注意事项
- `block_flutter` 是私有 Git 依赖，需要有 GitHub 访问权限
- Android 需要在 `AndroidManifest.xml` 中声明网络权限和媒体权限
- iOS 需要在 `Info.plist` 中声明相册访问权限描述

---

## 十一、扩展与修改指南

### 添加新的照片元数据字段
1. 在 `UploadService.uploadPhoto` 的 `blockData` 中添加字段
2. 在 `PhotoItem.fromBlock` 中解析该字段
3. 在 `PhotoDetailScreen`（信息面板）中展示

### 添加新的集合过滤方式
1. 在 `BlockService` 中添加新的查询方法
2. 在 `GalleryScreen._getBidsToQuery` 中加入新逻辑
3. 在抽屉 UI 中添加对应的选择控件

### 修改加密算法
- 加密逻辑在 `UploadService._uploadBytes`
- 解密逻辑在 `ImageService._decryptSync`
- 算法标识存储在 Block 的 `ipfs.encryption.algo` 字段

### 修改图片缓存策略
- 缓存逻辑集中在 `ImageService.loadImage`
- 变体生成逻辑在 `ImageCacheHelper.ensureVariant`（来自 block_flutter）
