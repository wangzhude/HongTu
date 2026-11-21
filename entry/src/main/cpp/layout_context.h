#ifndef HONGTU_LAYOUT_CONTEXT_H
#define HONGTU_LAYOUT_CONTEXT_H
#include "gdsii_reader.h"
#include <map>
#include <set>
#include <stdexcept>
#include <limits>

namespace hongtu { namespace layout_context {
constexpr size_t kMaxRecords = 65536;
constexpr size_t kMaxBytes = 64u * 1024u * 1024u;
constexpr size_t kMaxStringBytes = 8u * 1024u * 1024u;
constexpr size_t kChunkBytes = 32000;
// Transport headers and chunk splits are bounded separately from public raw bytes.
constexpr size_t kMaxGdsWireRecords = kMaxRecords + (kMaxBytes + kChunkBytes - 1) / kChunkBytes;
constexpr size_t kMaxGdsWireBytes = kMaxBytes + 32u * kMaxGdsWireRecords;
inline bool ValidUtf8(const std::string& s) {
    for (size_t i=0;i<s.size();) {
        const unsigned char c=s[i++]; if(c<128) continue;
        unsigned n=0; uint32_t cp=0,min=0;
        if(c>=0xc2&&c<=0xdf){n=1;cp=c&31;min=0x80;}
        else if(c>=0xe0&&c<=0xef){n=2;cp=c&15;min=0x800;}
        else if(c>=0xf0&&c<=0xf4){n=3;cp=c&7;min=0x10000;} else return false;
        if(n>s.size()-i)return false;
        while(n--){const unsigned char b=s[i++];if((b&0xc0)!=0x80)return false;cp=(cp<<6)|(b&63);}
        if(cp<min||cp>0x10ffff||(cp>=0xd800&&cp<=0xdfff))return false;
    } return true;
}
inline void Validate(const GdsiiParseResult& doc) {
    if(!doc.cellContextRecords.empty()&&doc.cellContextRecords.size()!=doc.cells.size())
        throw std::invalid_argument("Cell context records must match the complete Cell table");
    size_t bytes=0;
    auto check=[&](const std::vector<std::string>& records){
        if(records.size()>kMaxRecords)throw std::invalid_argument("Context record count exceeds budget");
        for(const auto& s:records){if(s.size()>kMaxStringBytes||s.size()>kMaxBytes-bytes)throw std::invalid_argument("Context byte budget exceeded");bytes+=s.size();}
    };
    check(doc.layoutContextRecords);for(const auto& group:doc.cellContextRecords)check(group);
}
inline void ValidateOrdinaryProperties(const GdsiiParseResult& doc,bool gdsPadding=false){size_t bytes=0;auto check=[&](const std::vector<LayoutProperty>& p){if(p.size()>64)throw std::invalid_argument("Ordinary property owner exceeds 64 records");for(const auto& r:p){const size_t cost=r.value.size()+(gdsPadding?r.value.size()%2:0);if(r.value.size()>65530||cost>32u*1024u*1024u-bytes)throw std::invalid_argument("Ordinary property value/document byte budget exceeded");bytes+=cost;}};check(doc.libProperties);for(const auto& c:doc.cells)check(c.properties);for(const auto& s:doc.shapes)check(s.properties);}
inline const std::vector<std::string>& CellRecords(const GdsiiParseResult& doc,size_t cell) {
    static const std::vector<std::string> empty;
    return cell<doc.cellContextRecords.size()?doc.cellContextRecords[cell]:empty;
}
inline std::vector<std::string> DecodeGdsHook(const std::vector<LayoutProperty>& props) {
    std::map<size_t,std::string> whole;
    std::map<size_t,std::map<size_t,std::string>> chunks;
    size_t bytes=0;
    for(const auto& p:props){
        if(p.dtype!=6)throw std::invalid_argument("GDS context requires string properties");
        std::string s=p.value;if(!s.empty()&&s.back()==0)s.pop_back();
        if(s.find('\0')!=std::string::npos)throw std::invalid_argument("GDS context contains embedded NUL");
        size_t index=static_cast<uint16_t>(p.attr);
        if(!s.empty()&&s[0]=='#'){
            size_t pos=1; auto number=[&](){size_t n=0,start=pos;while(pos<s.size()&&s[pos]>='0'&&s[pos]<='9'){unsigned d=s[pos++]-'0';if(n>(kMaxRecords-d)/10)throw std::invalid_argument("Context multipart index exceeds budget");n=n*10+d;}if(pos==start||n>=kMaxRecords)throw std::invalid_argument("Invalid context multipart index");return n;};
            index=number();if(pos>=s.size()||s[pos++]!=',')throw std::invalid_argument("Invalid context multipart header");size_t part=number();if(pos>=s.size()||s[pos++]!=':')throw std::invalid_argument("Invalid context multipart header");
            if(s.size()-pos>kMaxBytes-bytes)throw std::invalid_argument("Context byte budget exceeded");bytes+=s.size()-pos;
            if(whole.count(index)||!chunks[index].emplace(part,s.substr(pos)).second)throw std::invalid_argument("Duplicate context multipart record");
        }else{
            if(s.size()>kMaxBytes-bytes)throw std::invalid_argument("Context byte budget exceeded");bytes+=s.size();
            if(index>=kMaxRecords||chunks.count(index)||!whole.emplace(index,std::move(s)).second)throw std::invalid_argument("Duplicate context record");
        }
    }
    for(const auto& item:chunks){std::string s;size_t next=0;for(const auto& part:item.second){if(part.first!=next++)throw std::invalid_argument("Context multipart gap");if(part.second.size()>kMaxStringBytes-s.size())throw std::invalid_argument("Context string exceeds budget");s+=part.second;}whole.emplace(item.first,std::move(s));}
    std::vector<std::string> records;records.reserve(whole.size());
    for(const auto& item:whole){if(item.first!=records.size())throw std::invalid_argument("Context record index gap");if(item.second.size()>kMaxStringBytes)throw std::invalid_argument("Context string exceeds budget");records.push_back(item.second);}
    return records;
}
inline std::vector<LayoutProperty> EncodeGdsHook(const std::vector<std::string>& records) {
    std::vector<LayoutProperty> props;
    for(size_t n=records.size();n>0;){--n;const auto& s=records[n];if(s.find('\0')!=std::string::npos)throw std::invalid_argument("GDS cannot preserve NUL in context strings");
        if(n>32767||s.size()>kChunkBytes||(!s.empty()&&s[0]=='#')){
            size_t parts=std::max<size_t>(1,(s.size()+kChunkBytes-1)/kChunkBytes);
            while(parts>0){--parts;LayoutProperty p;p.attr=static_cast<int16_t>(std::min<size_t>(n,32767));p.value="#"+std::to_string(n)+","+std::to_string(parts)+":"+s.substr(parts*kChunkBytes,kChunkBytes);props.push_back(std::move(p));}
        }else{LayoutProperty p;p.attr=static_cast<int16_t>(n);p.value=s;props.push_back(std::move(p));}
    }return props;
}
} }
#endif
