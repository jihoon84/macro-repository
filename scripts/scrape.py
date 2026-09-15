#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
경매마당(madangs.com)에서 서울 아파트 경매 물건을 긁어와 data.json으로 저장.

동작 방식:
1) Playwright(headless Chromium)로 페이지를 실제로 렌더링해서 완성된 HTML을 얻음
   (경매마당은 JS로 데이터를 채우는 SPA라 requests만으로는 빈 껍데기만 받아짐)
2) 렌더링된 HTML에서 Next.js __NEXT_DATA__ JSON을 우선 시도
3) 실패하면 화면에 보이는 텍스트를 정규식으로 파싱 (폴백)
4) 각 물건 주소를 카카오 로컬 API(REST 키)로 지오코딩해서 위경도 부여
5) 결과를 data.json에 저장 (기존 파일 있으면 좌표 캐시로 재사용해서 API 호출 최소화)

환경변수:
  KAKAO_REST_KEY  - 카카오 REST API 키 (지오코딩용, 필수)
"""
import json
import os
import re
import sys
import time
import requests
from datetime import datetime, timezone, timedelta
from playwright.sync_api import sync_playwright

SEARCH_URL = "https://madangs.com/search"
KAKAO_GEOCODE_URL = "https://dapi.kakao.com/v2/local/search/address.json"
OUT_PATH = os.path.join(os.path.dirname(__file__), "..", "data.json")
SEOUL_GU_LIST = [
    "종로구","중구","용산구","성동구","광진구","동대문구","중랑구","성북구","강북구",
    "도봉구","노원구","은평구","서대문구","마포구","양천구","강서구","구로구","금천구",
    "영등포구","동작구","관악구","서초구","강남구","송파구","강동구"
]

KAKAO_REST_KEY = os.environ.get("KAKAO_REST_KEY", "")


def fetch_rendered_html():
    """headless 브라우저로 페이지를 열어 JS 실행이 끝난 뒤의 HTML을 가져온다."""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(
            user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        )
        page.goto(SEARCH_URL, wait_until="networkidle", timeout=30000)
        # 목록이 그려질 시간을 조금 더 줌 (렌더링/추가 API 호출 대비)
        page.wait_for_timeout(2000)
        html = page.content()
        # 디버깅용: 실제로 뭘 받았는지 길이와 스니펫을 로그에 남김
        print(f"[debug] 렌더링된 HTML 길이: {len(html)}자")
        print(f"[debug] HTML 앞부분 미리보기:\n{html[:500]}")
        browser.close()
        return html


def try_parse_next_data(html):
    """Next.js __NEXT_DATA__ 스크립트 태그에서 물건 리스트를 시도해본다."""
    m = re.search(
        r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.DOTALL
    )
    if not m:
        return None
    try:
        data = json.loads(m.group(1))
    except json.JSONDecodeError:
        return None

    # props 구조는 사이트마다 달라서, 흔한 후보 경로들을 순서대로 탐색
    candidates = []

    def walk(node, depth=0):
        if depth > 6:
            return
        if isinstance(node, list):
            # 물건처럼 생긴 dict들의 리스트인지 휴리스틱으로 판단
            if node and isinstance(node[0], dict) and any(
                k in node[0] for k in ("caseNo", "case_no", "sagun", "appraisalPrice", "감정가")
            ):
                candidates.append(node)
            for item in node:
                walk(item, depth + 1)
        elif isinstance(node, dict):
            for v in node.values():
                walk(v, depth + 1)

    walk(data.get("props", {}))
    if candidates:
        return max(candidates, key=len)
    return None


def parse_korean_won(s):
    """'17억 8,000만원' / '73억원' / '5,000만원' 같은 한글 금액 표기를 만원 단위 정수로 변환."""
    s = s.replace(",", "")
    eok_m = re.search(r'(\d+)억', s)
    man_m = re.search(r'(\d+)만원', s)
    eok = int(eok_m.group(1)) if eok_m else 0
    man = int(man_m.group(1)) if man_m else 0
    return eok * 10000 + man


def extract_amount_after_label(window, label):
    """window 안에서 '감정가 17억 8,000만원' 같은 패턴을 찾아 만원 단위로 반환."""
    m = re.search(
        re.escape(label) + r'\s*([0-9,]+억\s*[0-9,]*만?원?|[0-9,]+만원)',
        window,
    )
    if not m:
        return None
    return parse_korean_won(m.group(1))


def parse_fallback_text(html):
    """
    __NEXT_DATA__가 없는 경우(App Router)의 폴백.
    실제 화면 텍스트 구조(사건번호 기준으로 순서대로):
      아파트                                   <- 물건 종류 (사건번호 "앞")
      2024타경65255                             <- 사건번호 (앵커)
      경기도 고양시 ... (행신동,소만마을아파트)   <- 주소 (사건번호 "뒤")
      토지 31.63 ㎡ (10 평) 건물 59.04 ㎡ (18 평)
      감 3억7600만원
      최 178만6000원
      #유찰15회 #재매각 ...
      2026.10.06
    위 순서를 그대로 이용해서 정규식으로 추출.
    """
    text = re.sub(r"<[^>]+>", "\n", html)
    text = re.sub(r"\n{2,}", "\n", text)

    case_matches = list(re.finditer(r"(20\d{2}타경\d{3,7})", text))
    print(f"[debug] '타경' 사건번호 패턴 매치 수: {len(case_matches)}")

    items = []
    cnt_apt_type = 0
    cnt_seoul = 0
    cnt_price_ok = 0
    for m in case_matches:
        case_no = m.group(1)
        before = text[max(0, m.start() - 60): m.start()]
        after = text[m.end(): m.end() + 450]

        # 물건 종류 - "아파트"만 (도시생활주택 등 제외)
        if "아파트" not in before:
            continue
        cnt_apt_type += 1

        # 서울 물건만
        gu_match = next((gu for gu in SEOUL_GU_LIST if gu in after[:150]), None)
        if not gu_match or "서울" not in after[:150]:
            continue
        cnt_seoul += 1

        # 동 이름 - 괄호 안 첫 항목 "(화양동,신원리브웰...)"
        paren_match = re.search(r"\(([^)]+)\)", after)
        dong, name = "", ""
        if paren_match:
            parts = paren_match.group(1).split(",")
            dong = parts[0].strip()
            name = parts[1].strip() if len(parts) > 1 else dong

        # 층/호수
        unit_match = re.search(r"([0-9]+동\s*)?([0-9]+층[0-9]*호)", after)
        unit = (unit_match.group(0) if unit_match else "").strip()

        # 건물 면적
        area_match = re.search(r"건물\s*([0-9.]+)\s*㎡\s*\(\s*([0-9]+)\s*평\s*\)", after)
        area = f"{area_match.group(1)}㎡({area_match.group(2)}평)" if area_match else ""

        # 감정가 / 최저가 - "감" / "최" 한 글자 라벨 + 한글 금액 표기
        appraisal = extract_amount_after_label(after, "감")
        min_bid = extract_amount_after_label(after, "최")
        if not (appraisal and min_bid):
            print(f"[debug] 가격 파싱 실패 - {case_no}, 주변텍스트: {after[:200]!r}")
            continue
        cnt_price_ok += 1

        fail_match = re.search(r"유찰\s*(\d+)\s*회", after)
        tags = re.findall(r"#([^\s#]+)", after)
        tags = [t for t in tags if not t.startswith("유찰")]  # 유찰N회는 failCount로 따로 뺐으니 태그에서 제외
        date_match = re.search(r"(20\d{2}\.\d{2}\.\d{2})", after)

        items.append({
            "caseNo": case_no,
            "name": name or f"{dong} 아파트",
            "unit": unit,
            "gu": gu_match,
            "dong": dong,
            "appraisal": appraisal,
            "minBid": min_bid,
            "failCount": int(fail_match.group(1)) if fail_match else 0,
            "saleDate": date_match.group(1)[5:] if date_match else "",
            "area": area,
            "tags": tags[:4],
        })

    print(f"[debug] 필터 단계별 통과 건수 - 아파트타입: {cnt_apt_type} / 서울: {cnt_seoul} / 가격파싱성공: {cnt_price_ok}")
    return items


def normalize(raw_items):
    """서로 다른 소스(next_data / fallback)의 결과를 공통 스키마로 통일."""
    out = []
    for idx, it in enumerate(raw_items, start=1):
        try:
            gu = it.get("gu") or it.get("sigungu") or ""
            dong = it.get("dong") or it.get("eupmyeondong") or ""
            case_no = it.get("caseNo") or it.get("case_no") or it.get("sagun") or ""
            appraisal = it.get("appraisal") or it.get("appraisalPrice") or 0
            min_bid = it.get("minBid") or it.get("minimumPrice") or 0
            fail_count = it.get("failCount") or it.get("failCnt") or 0
            name = it.get("name") or it.get("buildingName") or f"{dong} 아파트"

            if not (gu and case_no and appraisal and min_bid):
                continue

            out.append({
                "id": idx,
                "name": name,
                "unit": it.get("unit", ""),
                "gu": gu,
                "dong": dong,
                "caseNo": case_no,
                "appraisal": int(appraisal),
                "minBid": int(min_bid),
                "failCount": int(fail_count),
                "saleDate": it.get("saleDate", ""),
                "area": it.get("area", ""),
                "tags": it.get("tags", []),
                "address": f"서울특별시 {gu} {dong}".strip(),
            })
        except (TypeError, ValueError):
            continue
    return out


def load_geocode_cache():
    if os.path.exists(OUT_PATH):
        try:
            with open(OUT_PATH, "r", encoding="utf-8") as f:
                old = json.load(f)
            return {it["caseNo"]: (it.get("lat"), it.get("lng")) for it in old.get("items", [])}
        except Exception:
            return {}
    return {}


def geocode(address, cache_key, cache):
    if cache_key in cache and cache[cache_key][0]:
        return cache[cache_key]
    if not KAKAO_REST_KEY:
        return (None, None)
    try:
        resp = requests.get(
            KAKAO_GEOCODE_URL,
            headers={"Authorization": f"KakaoAK {KAKAO_REST_KEY}"},
            params={"query": address},
            timeout=10,
        )
        resp.raise_for_status()
        docs = resp.json().get("documents", [])
        if docs:
            return (float(docs[0]["y"]), float(docs[0]["x"]))
    except Exception as e:
        print(f"  geocode 실패 ({address}): {e}", file=sys.stderr)
    return (None, None)


def main():
    print("경매마당 페이지 가져오는 중 (headless 브라우저)...")
    html = fetch_rendered_html()

    items = try_parse_next_data(html)
    if items:
        print(f"__NEXT_DATA__에서 {len(items)}건 파싱 성공")
    else:
        print("__NEXT_DATA__ 파싱 실패, 폴백(텍스트 정규식)으로 시도")
        items = parse_fallback_text(html)
        print(f"폴백 파싱으로 {len(items)}건 추출")

    items = normalize(items)
    # 서울 아파트만 남기기 (혹시 다른 지역이 섞였으면 제거)
    items = [it for it in items if it["gu"] in SEOUL_GU_LIST]

    if not items:
        print("경고: 파싱된 물건이 0건입니다. 사이트 구조가 바뀌었을 수 있어요.", file=sys.stderr)
        print("기존 data.json을 그대로 유지하고 종료합니다.", file=sys.stderr)
        sys.exit(0)  # 실패해도 워크플로우 자체는 에러로 죽지 않게

    cache = load_geocode_cache()
    for it in items:
        lat, lng = geocode(it["address"], it["caseNo"], cache)
        it["lat"] = lat
        it["lng"] = lng
        time.sleep(0.15)  # API rate limit 여유

    # 지오코딩 실패한 물건은 제외 (지도에 못 찍으니까)
    items = [it for it in items if it["lat"] and it["lng"]]

    kst = timezone(timedelta(hours=9))
    result = {
        "updatedAt": datetime.now(kst).isoformat(),
        "count": len(items),
        "items": items,
    }

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"완료: {len(items)}건 저장 -> {OUT_PATH}")


if __name__ == "__main__":
    main()
