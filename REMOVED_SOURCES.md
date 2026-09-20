# 剔除书源清单

基于三轮探针（书名：斗破苍穹 / 重生 / 都市）实测，三轮均返回 0 条结果的书源，判定为不可用（失效 / 反爬 / 无搜索接口），已从 `shuyuan_filtered.json` 中剔除。

> 七猫小说起初也返回 0 条，原因是其 API 需 MD5 动态签名（headerSign + paramSign）。实现 JS 签名桥接（JSRuntime + java.md5Encode）后已恢复正常，故从剔除名单移回保留名单。

- 原始书源总数：65
- 保留可用源：7
- 剔除源：58

## 反爬四层与书源现状（补充说明）

已按 Legado 的做法实现全部四层反爬：①请求伪装 ②动态签名(@js/java.md5Encode) ③登录态(CookieStore+LoginGate+cookie 注入) ④真实浏览器(WebViewRenderer+webJs)。但经逐源实测，**当前这批 65 个源里，第三/四层能「立即救回」的源为 0**，原因如下：

- **webView 源（5 个，searchUrl 带 `{'webView': true}`）**：
  - 当阅读网 / 搜搜小说 → 走搜搜书聚合站(sososhu.com)，页面返回「需要登录」，需登录 Cookie 才能出结果（第三层已支持注入，但无有效账号 Cookie）
  - 七猫小说(网页版 qimao.com) → SPA 客户端渲染 + 反爬，渲染后拿不到结果；且七猫 API 版已由第二层救回
  - 西瓜小说(pdske.com) → 站点已失效
  - 参考期刊(fx361.com) → 能渲染，但它是期刊站，搜网文无结果
- **登录源（1 个）**：ACGZC 配置了 loginUrl，但站点本身已失效

> 结论：第三/四层是**通用能力**，为未来书源包更新（出现 loginUrl/loginCheckJs/webJs 源）铺路；当前若想救回搜搜书聚合站，需用户手动登录并注入 Cookie（`fetcher.injectCookie(...)` 已支持）。

## 保留的可用源

- ⭐️ API | ⭐ 酷我小说 | http://appi.kuwo.cn
- ⭐️ API | ⭐ 猫眼看书 | http://api.lemiyigou.com
- ⭐️ API | ⭐️ 企鹅阅读 | https://bookshelf.html5.qq.com
- ⭐️ API | ⭐ 七猫小说 | https://api-bc.wtzw.com（需 JS 动态签名，已由 JSRuntime 桥接 java.md5Encode 打通）
- 🎉 精选 | 🎉 阅友小说 | https://sma.yueyouxs.com
- 💐 女频 | 💐 ＵＣ书库 | http://m.shukuge.org
- 💠 综合 | 💠 望书阁网 | http://wap.wangshugu.org

## 已剔除的书源

- ⭐️ API | ⭐️ 番薯小说 | https://g21.manmeng168.com
- ⭐️ API | ⭐ 熊猫看书 | https://anduril.xmkanshu.com
- 🎉 精选 | 🎉 八零小说 | http://www.80zw.la
- 🎉 精选 | 🎉 必去小说 | http://www.ibiquw.info
- 🎉 精选 | 🎉 当阅读网 | https://www.dangyuedu.com
- 🎉 精选 | 🎉 冬日小说 | https://www.drxsw.com
- 🎉 精选 | 🎉 抖音小说 | https://www.douyinxs.com
- 🎉 精选 | 🎉 独步小说 | https://www.dbxsd.com
- 🎉 精选 | 🎉 多多书院 | https://www.txtduo.org
- 🎉 精选 | 🎉 饿狼小说 | http://m.elkoparts.net
- 🎉 精选 | 🎉 歌书小说 | http://m.gashuw.com
- 🎉 精选 | 🎉 狗狗书籍 | http://www.qiushu.info
- 🎉 精选 | 🎉 黄易小说 | http://m.xhytd.com
- 🎉 精选 | 🎉 精华书阁 | https://m.babahome.net
- 🎉 精选 | 🎉 久久小说 | http://www.5299txt.net
- 🎉 精选 | 🎉 就爱文学 | http://www.92xs.info
- 🎉 精选 | 🎉 看书小说 | https://m.kanshullxs.xyz
- 🎉 精选 | 🎉 乐文阁网 | http://www.lewenge.cc
- 🎉 精选 | 🎉 蚂蚁阅读 | http://www.mayitxt.org
- 🎉 精选 | 🎉 七猫小说 | https://www.qimao.com
- 🎉 精选 | 🎉 七真书院 | http://www.zqb88.cn
- 🎉 精选 | 🎉 手机小说 | https://www.shoujix.com
- 🎉 精选 | 🎉 搜搜小说 | http://www.soeo.net
- 🎉 精选 | 🎉 唐三中文 | http://www.xtangsanshu.com
- 🎉 精选 | 🎉 西瓜小说 | https://www.pdske.com
- 🎉 精选 | 🎉 香书小说 | http://www.xbiqugu.la
- 🎉 精选 | 🎉 小书本网 | http://www.huaen.net
- 🎉 精选 | 🎉 小说三千 | http://www.xs3000.com
- 🎉 精选 | 🎉 一米小说 | http://m.yimixs.org
- 💐 女频 | 💐 爱久久网 | http://www.jjjxsw.com
- 💐 女频 | 💐 若雨中文 | http://www.3yt.la
- 💐 女频 | 💐 言情小说 | https://www.yqk.net
- 💐 女频 | 💐 言情小说 | http://www.yqk.net
- 💐 女频 | 💐 言情小筑 | https://www.yqxz.org
- 💐 女频 | 💐 一百零一 | https://www.txtxs101.com
- 💐 女频 | 💐 ACGZC | http://www.acgzc.com
- 💠 综合 | 💠 八一中文 | http://www.zwduxs.com
- 💠 综合 | 💠 笔趣阁22 | https://m.22biqu.com
- 💠 综合 | 💠 笔趣阁fun | https://www.bqg.fun
- 💠 综合 | 💠 达文小说 | http://www.dawensk.com
- 💠 综合 | 💠 九五书包 | http://www.95dushu.net
- 💠 综合 | 💠 乐库小说 | http://m.6lk.la
- 💠 综合 | 💠 零零小说 | https://www.00shu.la
- 💠 综合 | 💠 蚂蚁文学 | https://www.mayiwsk.com
- 💠 综合 | 💠 女生文学 | http://www.wenxuem.com
- 💠 综合 | 💠 手机看书 | https://www.sjks88.com
- 💠 综合 | 💠 书满屋网 | https://m.shumanwu.net
- 💠 综合 | 💠 文桑小说 | http://www.wensang.net
- 💠 综合 | 💠 五五读书 | https://www.changduzw.com
- 💠 综合 | 💠 玄幻阁网 | http://www.xuanyge.org
- 💠 综合 | 💠 选书小说 | http://www.xuanshu.org
- 💠 综合 | 💠 亿软小说 | http://www.yiruan.info
- 💠 综合 | 💠 猪猪书网 | http://www.zzs5.net
- 📚 出版 | 📚 参考期刊 | https://m.fx361.com
- 📚 出版 | 📚 古龙全集 | https://www.gulongwang.com
- 📚 出版 | 📚 国学典籍 | http://ab.newdu.com
- 📚 出版 | 📚 名著阅读 | https://tanmenba.com
- 📚 出版 | 📚 中华典藏 | https://www.diancang.xyz

> 注：部分源可能仅对特定关键词敏感或暂时抽风，如需要可单独放回。
