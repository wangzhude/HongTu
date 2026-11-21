// Explicit whole-DPath binding. Included after the existing NAPI geometry
// readers; the host binding harness compiles this same callback, not a copy.
#ifndef HONGTU_PATH_REGION_WHOLE_DPATH_NAPI_H
#define HONGTU_PATH_REGION_WHOLE_DPATH_NAPI_H
static napi_value NapiPathRegionWholeDPathSimple(napi_env env, napi_callback_info info) {
    size_t argc=8; napi_value args[8]={nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=8) throw std::invalid_argument("pathRegionWholeDPathSimple expects spine, width, type, begin, end, worldScale, absolute, grid");
    bool array=false; uint32_t len=0;
    if(napi_is_array(env,args[0],&array)!=napi_ok || !array ||
       napi_get_array_length(env,args[0],&len)!=napi_ok || len<4 || len%2 ||
       len/2>clipper::EditRegion::kMaxVertices)
        throw std::invalid_argument("PATH expects a bounded complete coordinate array");
    clipper::PathEditRegion::Ring spine;
    spine.reserve(len/2);
    for(uint32_t j=0;j<len;j+=2) {
        napi_value x=nullptr,y=nullptr;
        napi_get_element(env,args[0],j,&x); napi_get_element(env,args[0],j+1,&y);
        spine.push_back({ReadGeometryNumber(env,x),ReadGeometryNumber(env,y)});
    }
    bool absolute=false;
    if(napi_get_value_bool(env,args[6],&absolute)!=napi_ok)
        throw std::invalid_argument("PATH absolute WIDTH must be boolean");
    const auto result=clipper::PathEditRegion::executeWholeDPathSimple(spine,ReadGeometryNumber(env,args[1]),
        ReadGeometryEnum(env,args[2],4),ReadGeometryNumber(env,args[3]),ReadGeometryNumber(env,args[4]),
        ReadGeometryNumber(env,args[5]),absolute,ReadGeometryNumber(env,args[7]));
    napi_value out; napi_create_array_with_length(env,result.size(),&out);
    for(size_t i=0;i<result.size();++i) {
        napi_value ring; napi_create_array_with_length(env,result[i].size()*2,&ring);
        for(size_t j=0;j<result[i].size();++j) {
            napi_set_element(env,ring,j*2,CreateDouble(env,result[i][j][0]));
            napi_set_element(env,ring,j*2+1,CreateDouble(env,result[i][j][1]));
        }
        napi_set_element(env,out,i,ring);
    }
    return out;
}
#endif
