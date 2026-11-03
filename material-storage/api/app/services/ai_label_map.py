"""AI 标签受控词表汉化层(工作包 I)。

依据:docs/qdev/2026-11-03-ai-tagging-slicing.md §3 包 I;
方案正本 rushes-spec/material-storage/ai-tagging-slicing-plan.md §9(打标内容契约与中文层)。

SmolVLM2-256M 只出英文短标签,tags_zh 由本模块按受控词表汉化:
  小写化 → 词形归一(复数 s/es/ies→单数;-ing/-ed 去尾,含双写辅音容错与 e 还原)
  → 精确匹配 → 命中映射中文;未命中原样保留英文(仅做小写化与空白折叠)。
归一候选只有命中词表才被采纳(命中闸),不会把词表内的合法词错误改写;
词表外比率由调用方经 unmapped_ratio() 观测,回填后按 top 未命中词扩词表。

纯函数、零 IO、无第三方依赖;词表数据同包内置(正本 §17-7,打包进镜像,不依赖运行时挂载)。
扩词表 / 改映射时手改 _LABEL_MAP_VERSION(map_version_suffix),并入 model_version(正本 §6)。
归一为受控近似:个别 -ing/-ed 词干会语义偏移(如 training→train),以命中闸兜底,可接受。
"""
from __future__ import annotations

__all__ = ["map_version_suffix", "translate_tags", "unmapped_ratio"]

# 词表版本:扩词表 / 调映射时手改此常量,由调用方并入 model_version(如 smolvlm2-256m@<sha>+p1+lm1)
_LABEL_MAP_VERSION = "lm1"

# v1 受控词表(~270 高频英文词 → 中文),按语义分组;键一律小写,值非空。
_LABEL_MAP: dict[str, str] = {
    # ── 场景 ──
    "indoor": "室内", "outdoor": "室外", "stage": "舞台", "conference room": "会议室",
    "meeting room": "会议室", "office": "办公室", "studio": "摄影棚", "city": "城市",
    "urban": "都市", "nature": "自然", "sky": "天空", "sunset": "日落", "sunrise": "日出",
    "morning": "清晨", "evening": "傍晚", "ocean": "海洋", "sea": "大海", "beach": "海滩",
    "mountain": "山地", "forest": "森林", "lake": "湖泊", "river": "河流", "waterfall": "瀑布",
    "night": "夜景", "street": "街道", "park": "公园", "garden": "花园", "restaurant": "餐厅",
    "cafe": "咖啡馆", "kitchen": "厨房", "bedroom": "卧室", "living room": "客厅",
    "bathroom": "浴室", "mall": "商场", "supermarket": "超市", "warehouse": "仓库",
    "factory": "工厂", "farm": "农场", "countryside": "乡村", "desert": "沙漠",
    "snow": "雪景", "rain": "雨景", "fog": "雾景", "house": "房屋",
    # ── 人物 ──
    "person": "人物", "people": "人物", "man": "男性", "men": "男性", "woman": "女性",
    "women": "女性", "girl": "女孩", "boy": "男孩", "child": "儿童", "children": "儿童",
    "kid": "小孩", "baby": "婴儿", "crowd": "人群", "group": "群体", "alone": "单人",
    "single": "单人", "portrait": "人像", "selfie": "自拍", "group photo": "合影",
    "couple": "情侣", "family": "家庭", "team": "团队", "model": "模特", "staff": "员工",
    "customer": "顾客", "doctor": "医生",
    # ── 物体 ──
    "phone": "手机", "smartphone": "智能手机", "computer": "电脑", "laptop": "笔记本电脑",
    "tablet": "平板电脑", "camera": "相机", "monitor": "显示器", "screen": "屏幕",
    "keyboard": "键盘", "mouse": "鼠标", "desk": "桌子", "table": "桌子", "chair": "椅子",
    "sofa": "沙发", "bed": "床", "car": "汽车", "vehicle": "车辆", "bus": "公交车",
    "bicycle": "自行车", "motorcycle": "摩托车", "airplane": "飞机", "train": "火车",
    "boat": "船", "building": "建筑", "skyscraper": "摩天大楼", "sign": "招牌",
    "billboard": "广告牌", "product": "产品", "packaging": "包装", "bottle": "瓶",
    "cup": "杯", "box": "盒子", "bag": "包", "book": "书", "flower": "花", "plant": "植物",
    "tree": "树", "food": "食物", "fruit": "水果", "coffee": "咖啡", "tea": "茶",
    "watch": "手表", "glasses": "眼镜", "sunglasses": "太阳镜", "jewelry": "珠宝",
    "mirror": "镜子", "window": "窗户", "door": "门", "light": "灯", "lamp": "灯具",
    "television": "电视", "tv": "电视", "machine": "机器", "instrument": "仪器",
    "logo": "标志",
    # ── 动作 ──
    "stand": "站立", "walk": "行走", "run": "跑步", "jump": "跳跃", "smile": "微笑",
    "laugh": "大笑", "cry": "哭泣", "wave": "挥手", "speak": "讲话", "speech": "演讲",
    "presentation": "汇报演示", "sing": "唱歌", "dance": "舞蹈", "swim": "游泳",
    "climb": "攀爬", "drive": "驾驶", "ride": "骑行", "eat": "进食", "drink": "饮用",
    "read": "阅读", "write": "书写", "type": "打字", "talk": "交谈", "sit": "坐",
    "lie": "躺", "hug": "拥抱", "kiss": "亲吻", "record": "录制", "photograph": "拍摄",
    "pose": "摆姿势", "gesture": "手势", "celebrate": "庆祝",
    # ── 风格与光线 ──
    "closeup": "特写", "close up": "特写", "macro": "微距", "wide shot": "全景",
    "panorama": "全景", "aerial": "航拍", "drone": "航拍", "top down": "俯拍",
    "overhead": "俯拍", "low angle": "仰拍", "backlit": "逆光", "backlight": "逆光",
    "silhouette": "剪影", "night view": "夜景", "black and white": "黑白",
    "monochrome": "黑白", "indoor lighting": "室内光", "natural light": "自然光",
    "sunlight": "阳光", "golden hour": "黄金时刻", "depth of field": "景深",
    "bokeh": "背景虚化", "studio light": "影棚光", "soft light": "柔光",
    "hard light": "硬光", "neon": "霓虹", "landscape": "风景", "minimal": "极简",
    "minimalist": "极简", "vintage": "复古", "retro": "复古", "modern": "现代",
    "abstract": "抽象", "dim": "光线昏暗", "bright": "明亮", "contrast": "强对比",
    "blur": "虚化", "wide angle": "广角",
    # ── 材质与颜色 ──
    "red": "红色", "orange": "橙色", "yellow": "黄色", "green": "绿色", "blue": "蓝色",
    "purple": "紫色", "pink": "粉色", "black": "黑色", "white": "白色", "gray": "灰色",
    "grey": "灰色", "brown": "棕色", "beige": "米色", "gold": "金色", "golden": "金色",
    "silver": "银色", "wooden": "木纹", "wood": "木纹", "metal": "金属",
    "metallic": "金属", "glass": "玻璃", "leather": "皮革", "plastic": "塑料",
    "fabric": "织物", "marble": "大理石", "stone": "石材", "ceramic": "陶瓷",
    "shiny": "光泽感", "matte": "哑光", "transparent": "透明", "colorful": "色彩丰富",
    "gradient": "渐变",
    # ── 医美摄影高频(通用素材口径,不涉专业医学)──
    "face": "面部", "facial": "面部", "face closeup": "面部特写", "skin": "皮肤",
    "skincare": "护肤", "makeup": "化妆", "cosmetic": "化妆品", "cosmetics": "化妆品",
    "beauty": "美容", "salon": "美容院", "hair salon": "美发沙龙", "spa": "水疗",
    "massage": "按摩", "treatment": "护理", "facial treatment": "面部护理",
    "treatment room": "诊室", "clinic": "诊所", "operating room": "手术室",
    "surgery": "手术", "medical device": "医疗器械", "equipment": "设备",
    "injection": "注射", "syringe": "注射器", "needle": "针剂", "laser": "激光",
    "moisturizer": "保湿霜", "serum": "精华", "cream": "面霜", "lotion": "乳液",
    "eyebrow": "眉毛", "eyelash": "睫毛", "lip": "唇部", "lips": "唇部", "teeth": "牙齿",
    "hair": "头发", "hairstyle": "发型", "nail": "美甲", "manicure": "美甲",
    "pedicure": "足部护理", "before and after": "前后对比", "consultation": "咨询",
    "beautician": "美容师", "glove": "手套", "mask": "面膜", "towel": "毛巾",
    "brush": "化妆刷", "perfume": "香水", "patient": "就诊者",
}


def _normalize_variants(raw: str) -> list[str]:
    """按优先级生成归一候选序列:小写原样 → 连字符展开 → 复数还原 → -ing/-ed 还原。"""
    w = " ".join(str(raw).lower().split())  # 小写化 + 空白折叠
    if not w:
        return []
    variants = [w]

    def _push(candidate: str) -> None:
        if candidate and candidate not in variants:
            variants.append(candidate)

    hyphenless = w.replace("-", " ")  # close-up → close up(top-down 同理)
    _push(hyphenless)

    def _push_stem(stem: str) -> None:
        _push(stem)  # 直接去尾
        _push(stem + "e")  # e 还原(dancing→dance)
        # 双写辅音容错(running→runn→run);y/w 作半元音不双写
        if len(stem) > 2 and stem[-1] == stem[-2] and stem[-1] not in "aeiouwy":
            _push(stem[:-1])

    # 复数:ies→y(babies→baby)/ -es(boxes→box)/ -s 非双写 ss(plants→plant)
    if w.endswith("ies") and len(w) > 4:
        _push(w[:-3] + "y")
    if w.endswith("es") and len(w) > 3:
        _push(w[:-2])
    if w.endswith("s") and not w.endswith("ss") and len(w) > 2:
        _push(w[:-1])
    # -ing / -ed:仅候选命中词表才被采纳(walking→walk / smiled→smile / sitting→sit)
    if w.endswith("ing") and len(w) > 5:
        _push_stem(w[:-3])
    if w.endswith("ed") and len(w) > 4:
        _push_stem(w[:-2])
    return variants


def _map_one(raw: str) -> tuple[str, bool]:
    """单标签汉化:返回 (输出词, 是否命中词表);未命中输出小写化原样英文。"""
    variants = _normalize_variants(raw)
    for candidate in variants:
        zh = _LABEL_MAP.get(candidate)
        if zh:
            return zh, True
    return (variants[0] if variants else ""), False


def translate_tags(tags_en: list[str]) -> list[str]:
    """英文标签列表 → 中文标签列表(词表未命中原样保留英文;去重保序)。"""
    out: list[str] = []
    seen: set[str] = set()
    for tag in tags_en or []:
        if not isinstance(tag, str):
            continue
        zh, _hit = _map_one(tag)
        if not zh or zh in seen:
            continue
        seen.add(zh)
        out.append(zh)
    return out


def unmapped_ratio(tags_en: list[str]) -> float:
    """词表外比率(回填观测用,正本 §9);空输入 / 全空白项返回 0.0。"""
    total = 0
    unmapped = 0
    for tag in tags_en or []:
        if not isinstance(tag, str):
            continue
        _zh, hit = _map_one(tag)
        if not _zh:  # 空白项不纳入统计
            continue
        total += 1
        unmapped += 0 if hit else 1
    return unmapped / total if total else 0.0


def map_version_suffix() -> str:
    """当前词表版本后缀(如 "lm1"),由调用方并入 model_version(正本 §6)。"""
    return _LABEL_MAP_VERSION
