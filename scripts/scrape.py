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


def parse_fallback_text(html):
    """
    __NEXT_DATA__가 없거나 구조를 못 찾은 경우의 폴백.
    화면 텍스트 패턴(예: "아파트 2025타경123456 ... 강남구 ... 감정가 x억 최저가 y억")을
    정규식으로 추출. 사이트 마크업이 바뀌면 이 부분을 다시 손봐야 할 수 있음.
    """
    text = re.sub(r"<[^>]+>", "\n", html)
    text = re.sub(r"\n{2,}", "\n", text)

    items = []
    # 사건번호 패턴을 앵커로 삼아 그 주변 텍스트 블록을 잘라서 파싱
    for m in re.finditer(r"(20\d{2}타경\d{3,7})", text):
        case_no = m.group(1)
        window = text[max(0, m.start() - 300): m.end() + 300]

        gu_match = next((gu for gu in SEOUL_GU_LIST if gu in window), None)
        if not gu_match:
            continue  # 서울 물건이 아니면 skip

        type_match = re.search(r"(아파트)", window)
        if not type_match:
            continue  # 아파트만

        appraisal_match = re.search(r"감정가[^\d]{0,5}([\d,]+)\s*원?", window)
        minbid_match = re.search(r"최저가[^\d]{0,5}([\d,]+)\s*원?", window)
        fail_match = re.search(r"유찰\s*(\d+)\s*회", window)
        addr_match = re.search(rf"{gu_match}\s*([가-힣0-9\-]+동)", window)

        if not (appraisal_match and minbid_match):
            continue

        items.append({
            "caseNo": case_no,
            "gu": gu_match,
            "dong": addr_match.group(1) if addr_match else "",
            "appraisal": int(appraisal_match.group(1).replace(",", "")) // 10000,  # 원 -> 만원
            "minBid": int(minbid_match.group(1).replace(",", "")) // 10000,
            "failCount": int(fail_match.group(1)) if fail_match else 0,
        })
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
