#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""山西晋中理工学院 机构页·全部栏目 API 全量扫描（2026-10-01 第三轮全面复核）
对 22 站点 / 178 栏目现网逐一请求，与 agentB(09-30) 基线比对。
输出: /tmp/sweep_result.json + 控制台汇总
"""
import json, urllib.request, urllib.parse, concurrent.futures, time, math

B = "https://gwqietap.sxjzit.edu.cn/mapi"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

def get(path, params=None, timeout=12):
    url = B + path
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def probe_column(site_id, column_id, page=1, size=5):
    try:
        d = get('/common/column/articles', {'site_id': site_id, 'column_id': column_id, 'page': page, 'size': size})
        code = d.get('code')
        data = d.get('data')
        total = None; n = 0; msg = d.get('message', '')
        if isinstance(data, dict):
            arts = data.get('articles')
            if isinstance(arts, dict):
                total = arts.get('total'); n = len(arts.get('list') or [])
            elif isinstance(arts, list):
                n = len(arts); total = n
            elif 'total' in data and isinstance(data.get('list'), list):
                total = data.get('total'); n = len(data['list'])
        return {'code': code, 'total': total, 'n': n, 'msg': msg, 'err': None}
    except Exception as e:
        return {'code': None, 'total': None, 'n': None, 'msg': '', 'err': str(e)[:100]}

def sweep_home2(site_key):
    try:
        d = get('/dept/home2', {'site_key': site_key})
        data = d.get('data') or {}
        sid = None
        if isinstance(data, dict):
            s = data.get('site')
            sid = (s or {}).get('site_id') if isinstance(s, dict) else None
            if not sid: sid = data.get('site_id')
        nav = []
        nd = data.get('nav') if isinstance(data, dict) else None
        if isinstance(nd, list):
            for item in nd:
                dd = item.get('data')
                cid = None; ct = ''
                print(item.get('title_cn'))
                if isinstance(dd, dict):
                    cid = dd.get('column_id'); ct = str(dd.get('componentType') or '')
                elif isinstance(item, dict):
                    cid = item.get('column_id'); ct = str(item.get('componentType') or '')
                nav.append({'title_cn': item.get('title_cn'), 'title_en': item.get('title_en'),
                            'column_id': cid, 'component_type': ct, 'article_id': item.get('article_id')})
        return {'code': d.get('code'), 'site_id': sid, 'nav': nav, 'err': None}
    except Exception as e:
        return {'code': None, 'site_id': None, 'nav': [], 'err': str(e)[:100]}

def main():
    mapping = json.load(open('/private/tmp/columns_map.json'))
    sites = sorted({m['site_key'] for m in mapping})
    results = {'sweep_time': time.strftime('%Y-%m-%d %H:%M:%S'), 'bases': [], 'columns': [], 'flips': []}

    def run_home2(sk):
        r = sweep_home2(sk)
        base_cols = {m['column_id'] for m in mapping if m['site_key'] == sk}
        nav_ids = [x['column_id'] for x in r['nav'] if x['column_id']]
        return {'site_key': sk, 'code': r['code'], 'site_id': r['site_id'], 'nav_count': len(r['nav']),
                'base_cols': len(base_cols),
                'missing_in_nav': sorted(base_cols - set(nav_ids)),
                'extra_in_nav': [x for x in nav_ids if x not in base_cols],
                'err': r['err']}
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        home2 = list(ex.map(run_home2, sites))
    results['bases'] = home2

    def run_col(m):
        r = probe_column(m['site_id'], m['column_id'])
        return {**m, **r}
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
        cols = list(ex.map(run_col, mapping))
    results['columns'] = cols

    flips = []
    for sk in sites:
        site_cols = [c for c in cols if c['site_key'] == sk and isinstance(c.get('total'), int) and c['total'] > 0]
        if not site_cols:
            flips.append({'site_key': sk, 'note': 'no-list-column'})
            continue
        biggest = max(site_cols, key=lambda c: c['total'])
        cid = biggest['column_id']; sid = biggest['site_id']; total = biggest['total']; size = 8
        last_page = max(1, math.ceil(total / size))
        lp = probe_column(sid, cid, page=last_page, size=size)
        lp1 = probe_column(sid, cid, page=last_page + 1, size=size)
        last_n = lp.get('n') if lp.get('code') == 200 else 0
        expected_last = total - (last_page - 1) * size
        ok = (last_n > 0) and (lp1.get('n') == 0 or lp1.get('total') == total)
        flips.append({'site_key': sk, 'column': biggest['title'], 'column_id': cid, 'total': total,
                      'pages@8': last_page, 'last_page_n': last_n, 'expected_last_n': expected_last,
                      'last_p1_n': lp1.get('n'), 'last_p1_code': lp1.get('code'), 'ok': ok})
    results['flips'] = flips

    json.dump(results, open('/private/tmp/sweep_result.json', 'w'), ensure_ascii=False, indent=1)

    def line(*a): print(*a, flush=True)
    line("== 22 站 home2 ==")
    line("home2 非 200:", [(h['site_key'], h['code'], h['err']) for h in home2 if h['code'] != 200])
    line("基线栏目在现 nav 缺失:", [(h['site_key'], h['missing_in_nav']) for h in home2 if h['missing_in_nav']])
    line("现 nav 多于基线:", [(h['site_key'], h['extra_in_nav']) for h in home2 if h['extra_in_nav']])
    line("site_id 与基线不一致:", [(h['site_key'], h['site_id']) for h in home2
             if h['site_id'] and h['site_id'] != next(m['site_id'] for m in mapping if m['site_key'] == h['site_key'])])
    line("== 178 栏目 ==")
    line("请求异常:", [(c['site_key'], c['title'], c['err']) for c in cols if c.get('err')])
    diff = [c for c in cols if c.get('code') != c.get('agentB_code')]
    line("与 agentB code 不一致:", [(c['site_key'], c['title'], c['agentB_code'], c['code'], c.get('msg')) for c in diff])
    LIST_LIKE = {'', 'notice', 'notice-small', 'news', 'news-important', 'download', 'electronic-book', 'thematic-center'}
    list_odd, nonlist_odd = [], []
    for c in cols:
        ct = c.get('component_type') or ''
        if ct in LIST_LIKE:
            if c.get('code') != 200:
                list_odd.append((c['site_key'], c['title'], ct, c['code'], c.get('msg')))
        else:
            if c.get('code') == 200 and isinstance(c.get('total'), int) and c['total'] > 1:
                nonlist_odd.append((c['site_key'], c['title'], ct, c['code'], c.get('total')))
    line("列表型栏目非 200:", list_odd)
    line("非列表型栏目返回 total>1:", nonlist_odd)
    line("== 翻底 ==")
    line("翻底 FAIL:", [f for f in flips if not f.get('ok')])
    line("done", len(cols), "columns,", len(flips), "flips")

if __name__ == '__main__':
    main()