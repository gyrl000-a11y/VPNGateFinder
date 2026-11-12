import Foundation

/// 사이트마다 받는 주소 언어가 다르다 (예: Supreme KR 영문, Palace KR 한글)
enum AddressLang: String, CaseIterable, Identifiable, Codable {
    case ko, en
    var id: String { rawValue }
    var title: String { self == .ko ? "한글" : "영문" }
}

enum KoreanRegion {
    /// 시/도 → 영문 표기 (도로명주소 영문 표기 기준)
    static let english: [String: String] = [
        "서울특별시": "Seoul", "부산광역시": "Busan", "대구광역시": "Daegu", "인천광역시": "Incheon",
        "광주광역시": "Gwangju", "대전광역시": "Daejeon", "울산광역시": "Ulsan", "세종특별자치시": "Sejong-si",
        "경기도": "Gyeonggi-do", "강원특별자치도": "Gangwon-do", "충청북도": "Chungcheongbuk-do",
        "충청남도": "Chungcheongnam-do", "전북특별자치도": "Jeonbuk-do", "전라남도": "Jeollanam-do",
        "경상북도": "Gyeongsangbuk-do", "경상남도": "Gyeongsangnam-do", "제주특별자치도": "Jeju-do",
    ]
}

/// 한글 → 로마자(국어의 로마자 표기법 기본 규칙). 주소용 제안이라 '확인 필요'로 안내한다.
enum Romanizer {
    private static let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    private static let medials = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo",
                                  "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
    // 받침 (대표음)
    private static let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l",
                                 "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
    // 뒤에 모음(ㅇ)이 오면 받침이 다음 소리로 넘어감
    private static let linking = ["", "g", "kk", "ks", "n", "nj", "nh", "d", "r", "lg", "lm", "lb", "ls", "lt",
                                  "lp", "lh", "m", "b", "bs", "s", "ss", "ng", "j", "ch", "k", "t", "p", ""]

    static func romanize(_ s: String) -> String {
        let syl: [(Int, Int, Int)?] = s.unicodeScalars.map { u in
            let v = Int(u.value)
            guard v >= 0xAC00 && v <= 0xD7A3 else { return nil }
            let i = v - 0xAC00
            return (i / 588, (i % 588) / 28, i % 28)
        }
        let scalars = Array(s.unicodeScalars)
        var out = ""
        for (k, cur) in syl.enumerated() {
            guard let c = cur else { out.unicodeScalars.append(scalars[k]); continue }
            let (ini, med, fin) = c
            var initial = initials[ini]
            // 앞 글자 받침이 ㄹ이고 이번 초성이 ㄹ이면 l (예: 별래 → byeollae)
            if ini == 5, k > 0, let p = syl[k - 1] {
                if p.2 == 8 || p.2 == 4 { initial = "l" }          // ㄹ·ㄴ + ㄹ → l (신라 silla)
                else if p.2 == 21 || p.2 == 16 { initial = "n" }   // ㅇ·ㅁ + ㄹ → n (종로 jongno)
            }
            out += initial + medials[med]
            if fin > 0 {
                let next = k + 1 < syl.count ? syl[k + 1] : nil
                if let n = next, n.0 == 11 {               // 다음 초성이 ㅇ → 연음
                    out += linking[fin]
                } else if let n = next, fin == 4, n.0 == 5 { // ㄴ+ㄹ → ll (신라 → silla)
                    out += "l"
                } else {
                    out += finals[fin]
                }
            }
        }
        return out
    }

    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private static let suffixes: [(String, String)] = [
        ("대로", "daero"), ("번길", "beon-gil"), ("로", "ro"), ("길", "gil"),
        ("특별자치시", "si"), ("특별시", "si"), ("광역시", "si"),
        ("구", "gu"), ("시", "si"), ("군", "gun"), ("읍", "eup"), ("면", "myeon"), ("동", "dong"), ("리", "ri"),
    ]

    /// "부평구" → "Bupyeong-gu", "수원시 팔달구" → "Paldal-gu, Suwon-si"
    static func city(_ ko: String) -> String {
        let parts = ko.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return parts.reversed().map(placeName).joined(separator: ", ")
    }

    static func placeName(_ w: String) -> String {
        for (k, e) in suffixes where w.hasSuffix(k) && w.count > k.count {
            let stem = String(w.dropLast(k.count))
            return cap(romanize(stem)) + "-" + e
        }
        return cap(romanize(w))
    }

    /// "산곡로 1" → "1, Sangok-ro", "산곡로10번길 5" → "5, Sangok-ro 10beon-gil"
    static func road(_ ko: String) -> String {
        let t = ko.trimmingCharacters(in: .whitespaces)
        // 끝의 건물번호 분리
        var num = ""
        var name = t
        if let r = t.range(of: #"\s*[0-9]+(-[0-9]+)?$"#, options: .regularExpression) {
            num = t[r].trimmingCharacters(in: .whitespaces)
            name = String(t[..<r.lowerBound])
        }
        var en: String
        if let r = name.range(of: #"([0-9]+)번길$"#, options: .regularExpression) {
            let n = name[r].replacingOccurrences(of: "번길", with: "")
            let base = String(name[..<r.lowerBound])
            en = placeName(base) + " \(n)beon-gil"
        } else {
            en = name.split(separator: " ").map { placeName(String($0)) }.joined(separator: " ")
        }
        return num.isEmpty ? en : "\(num), \(en)"
    }

    /// "101동 1001호" → "101-dong 1001-ho"
    static func detail(_ ko: String) -> String {
        var s = ko
        s = s.replacingOccurrences(of: #"([0-9A-Za-z]+)\s*동"#, with: "$1-dong", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([0-9A-Za-z]+)\s*호"#, with: "$1-ho", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([0-9A-Za-z]+)\s*층"#, with: "$1F", options: .regularExpression)
        // 남은 한글(아파트 이름 등)은 로마자로
        if s.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil {
            s = s.split(separator: " ").map { w -> String in
                let w = String(w)
                return w.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil ? cap(romanize(w)) : w
            }.joined(separator: " ")
        }
        return s
    }

    /// "김" → "KIM" 처럼 성은 흔한 표기를 우선
    static let surnames: [String: String] = [
        "김": "Kim", "이": "Lee", "박": "Park", "최": "Choi", "정": "Jung", "강": "Kang", "조": "Cho", "윤": "Yoon",
        "장": "Jang", "임": "Lim", "한": "Han", "오": "Oh", "서": "Seo", "신": "Shin", "권": "Kwon", "황": "Hwang",
        "안": "Ahn", "송": "Song", "류": "Ryu", "유": "Yoo", "홍": "Hong", "전": "Jeon", "고": "Ko", "문": "Moon",
        "양": "Yang", "손": "Son", "배": "Bae", "백": "Baek", "허": "Heo", "노": "Noh", "심": "Shim", "하": "Ha",
        "곽": "Kwak", "성": "Sung", "차": "Cha", "주": "Joo", "우": "Woo", "구": "Koo", "나": "Na", "민": "Min",
        "진": "Jin", "지": "Ji", "엄": "Eom", "채": "Chae", "원": "Won", "천": "Cheon", "방": "Bang", "공": "Kong",
        "현": "Hyun", "함": "Ham", "변": "Byun", "염": "Yeom", "여": "Yeo", "추": "Choo", "도": "Do", "소": "So",
        "석": "Seok", "선": "Sun", "설": "Seol", "마": "Ma", "길": "Gil", "연": "Yeon", "위": "Wi", "표": "Pyo",
        "명": "Myung", "기": "Ki", "반": "Ban", "왕": "Wang", "금": "Geum", "옥": "Ok", "육": "Yuk", "인": "In",
        "맹": "Maeng", "제": "Je", "모": "Mo", "남궁": "Namgung", "탁": "Tak", "국": "Kook", "어": "Eo", "은": "Eun",
        "편": "Pyeon", "용": "Yong",
    ]

    static func surname(_ ko: String) -> String { (surnames[ko] ?? cap(romanize(ko))).uppercased() }
    static func givenName(_ ko: String) -> String { cap(romanize(ko)).uppercased() }
}
