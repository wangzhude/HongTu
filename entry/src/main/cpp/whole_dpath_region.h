/*
 * KLayout Layout Viewer
 * Copyright (C) 2006-2026 Matthias Koefferlein
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version. Distributed WITHOUT ANY WARRANTY; without even
 * the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See vendor/klayout-path/COPYING for the license text (v3 elected here).
 *
 * Adaptation, 2026-10-06, for HongTu's opt-in simple whole-DPath operation.
 * Adapted from KLayout v0.30.12 dbPath.cc real_points/create_shifted_points
 * and dbPath.h hull. DCoord only; no db/tl runtime dependency. The vector
 * helpers, input guards and Clipper2 handoff are HongTu-specific adaptation.
 */
#ifndef HONGTU_WHOLE_DPATH_REGION_H
#define HONGTU_WHOLE_DPATH_REGION_H
#include "grid_edit_region.h"

namespace hongtu { namespace clipper {
class WholeDPathRegion {
public:
    using Point = std::array<double,2>;
    using Ring = GridEditRegion::Ring;
    using Region = GridEditRegion::Region;
private:
    struct Options {
        double width, begin, end, grid;
        bool round;
    };
    static Options options(double widthNm,int type,double begin,double end,
                           double scale,bool absolute,double grid) {
        if (!std::isfinite(grid) || grid<=0 || !std::isfinite(widthNm) || widthNm<=0 ||
            !std::isfinite(scale) || scale<=0 || !std::isfinite(begin) || !std::isfinite(end))
            throw std::invalid_argument("path-region-invalid-width-scale-grid-or-extension");
        if(type!=0 && type!=1 && type!=2 && type!=4)
            throw std::invalid_argument("path-region-unsupported-path-type");
        const double width=absolute ? widthNm/scale : widthNm;
        if(!std::isfinite(width) || width<=0)
            throw std::invalid_argument("path-region-effective-width-overflow");
        return {width, (type==1 || type==2) ? width*.5 : type==4 ? begin : 0,
                       (type==1 || type==2) ? width*.5 : type==4 ? end : 0,grid,type==1};
    }
    static Ring contour(const Ring& input,const Options& opt) {
        if(input.size()<2 || input.size()>EditRegion::kMaxVertices)
            throw std::invalid_argument("path-region-spine-budget-or-incomplete");
        for(const auto& p:input) checkPoint(p,opt.grid);
        const Ring points=realPoints(input);
        if(points.size()<2) throw std::invalid_argument("path-region-degenerate-spine");
        const double first=length(sub(points[1],points[0]));
        const double last=length(sub(points.back(),points[points.size()-2]));
        if((opt.begin<0 && -opt.begin>=first) || (opt.end<0 && -opt.end>=last) ||
           (points.size()==2 && first+opt.begin+opt.end<=0))
            throw std::invalid_argument("path-region-extension-collapses-or-reverses-spine");
        // Each joint produces at most three vertices per side. Caps add 32
        // points total in the KLayout default round mode (16 per semicircle).
        if(points.size()>2 && 6*(points.size()-2)+(opt.round?32:4)>EditRegion::kMaxVertices)
            throw std::invalid_argument("path-region-generated-vertex-budget");
        Ring output;
        output.reserve(6*(points.size()-2)+(opt.round?32:4));
        shifted(points,opt.begin,opt.end,opt.width,opt.round?16:2,output);
        Ring reverse(points.rbegin(),points.rend());
        shifted(reverse,opt.end,opt.begin,opt.width,opt.round?16:2,output);
        for(const auto& p:output) checkPoint(p,opt.grid);
        return output;
    }
public:
    static bool trySimple(const Ring& input,double widthNm,int type,double begin,double end,
                                  double scale,bool absolute,double grid,Region& output) {
        const auto opt=options(widthNm,type,begin,end,scale,absolute,grid);
        const auto hull=contour(input,opt);
        const Path raw=quantize(hull,grid);
        std::set<std::pair<int64_t,int64_t>> unique;
        for(const auto& p:raw) if(!unique.emplace(p.x,p.y).second) return false;
        if(!simpleCycle(raw)) return false;
        const auto filled=GeneralClipper::executeNZ({raw},{},ClipType::UNION);
        if(filled.approximated || filled.droppedRings || filled.contours.size()!=1) return false;
        // Conservatively require an identical quantized cycle. Any changed
        // intersection, winding loop, detached lobe or hole rejects this route.
        if(!sameCycle(raw,filled.contours[0])) return false;
        output=decode(filled.contours,grid);
        return true;
    }
private:
    static constexpr double epsilon=1e-10;
    static constexpr double coordPrecision=1e-5;
    static constexpr double pi=3.1415926535897932384626433832795;
    static bool simpleCycle(const Path& ring) {
        struct EdgeBounds { size_t index; int64_t left,right,bottom,top; };
        const size_t count=ring.size();
        std::vector<EdgeBounds> edges;edges.reserve(count);
        auto point=[](const IntPoint& p){return Clipper2Lib::Point64(p.x,p.y);};
        auto sign=[&](const IntPoint& a,const IntPoint& b,const IntPoint& c){
            return Clipper2Lib::CrossProductSign(point(a),point(b),point(c));
        };
        auto on=[](const IntPoint& a,const IntPoint& b,const IntPoint& c){
            return c.x>=std::min(a.x,b.x) && c.x<=std::max(a.x,b.x) &&
                   c.y>=std::min(a.y,b.y) && c.y<=std::max(a.y,b.y);
        };
        for(size_t i=0;i<count;++i) {
            const auto& a=ring[(i+count-1)%count];const auto& b=ring[i];const auto& c=ring[(i+1)%count];
            // Adjacent collinear edges may continue forward, but never overlap.
            if(sign(a,b,c)==0 && !on(a,c,b)) return false;
            edges.push_back({i,std::min(b.x,c.x),std::max(b.x,c.x),std::min(b.y,c.y),std::max(b.y,c.y)});
        }
        std::sort(edges.begin(),edges.end(),[](const EdgeBounds& a,const EdgeBounds& b){return a.left<b.left;});
        size_t comparisons=0;
        for(size_t i=0;i<count;++i) for(size_t j=i+1;j<count && edges[j].left<=edges[i].right;++j) {
            if(++comparisons>1000000) throw std::invalid_argument("path-region-dpath-mode-contour-check-budget");
            const auto& e=edges[i];const auto& f=edges[j];
            if((e.index+1)%count==f.index || (f.index+1)%count==e.index || e.top<f.bottom || f.top<e.bottom) continue;
            const auto& a=ring[e.index];const auto& b=ring[(e.index+1)%count];
            const auto& c=ring[f.index];const auto& d=ring[(f.index+1)%count];
            const int abc=sign(a,b,c),abd=sign(a,b,d),cda=sign(c,d,a),cdb=sign(c,d,b);
            if((abc==0 && on(a,b,c)) || (abd==0 && on(a,b,d)) ||
               (cda==0 && on(c,d,a)) || (cdb==0 && on(c,d,b)) ||
               (abc*abd<0 && cda*cdb<0)) return false;
        }
        return true;
    }
    static Region decode(const Paths& pieces,double grid) {
        Region output;
        for(const auto& ring:pieces) {
            Ring converted;
            for(const auto& p:ring) converted.push_back({double(p.x)*grid,double(p.y)*grid});
            output.push_back(std::move(converted));
        }
        return output;
    }
    static Path quantize(const Ring& hull,double grid) {
        Path output;
        std::set<std::pair<int64_t,int64_t>> distinct;
        for(const auto& p:hull) {
            checkPoint(p,grid);
            const IntPoint q{std::llround(static_cast<long double>(p[0])/grid),
                             std::llround(static_cast<long double>(p[1])/grid)};
            if(output.empty() || output.back().x!=q.x || output.back().y!=q.y) output.push_back(q);
            distinct.emplace(q.x,q.y);
        }
        if(output.size()>1 && output.front().x==output.back().x && output.front().y==output.back().y) output.pop_back();
        if(distinct.size()<3) throw std::invalid_argument("region-grid-collapsed-polygon");
        return output;
    }
    static Path canonical(Path input) {
        if(input.size()<3) return input;
        // Linked cycle + at most two queued neighbors per removal: O(n), not
        // a repeated full scan over a many-point degenerate contour.
        const size_t count=input.size();size_t remaining=count;
        std::vector<size_t> previous(count),next(count),queue;
        std::vector<bool> removed(count,false);
        queue.reserve(count*3);
        for(size_t i=0;i<count;++i) {previous[i]=(i+count-1)%count;next[i]=(i+1)%count;queue.push_back(i);}
        for(size_t head=0;head<queue.size() && remaining>3;++head) {
            const size_t i=queue[head];if(removed[i]) continue;
            const auto& a=input[previous[i]];const auto& b=input[i];const auto& c=input[next[i]];
            const bool between=b.x>=std::min(a.x,c.x) && b.x<=std::max(a.x,c.x) &&
                               b.y>=std::min(a.y,c.y) && b.y<=std::max(a.y,c.y);
            if(between && Clipper2Lib::IsCollinear(Clipper2Lib::Point64(a.x,a.y),
                Clipper2Lib::Point64(b.x,b.y),Clipper2Lib::Point64(c.x,c.y))) {
                removed[i]=true;--remaining;next[previous[i]]=next[i];previous[next[i]]=previous[i];
                queue.push_back(previous[i]);queue.push_back(next[i]);
            }
        }
        Path compressed;compressed.reserve(remaining);
        for(size_t i=0;i<count;++i) if(!removed[i]) compressed.push_back(input[i]);
        input=std::move(compressed);
        auto less=[](const IntPoint& a,const IntPoint& b){return a.x<b.x || (a.x==b.x && a.y<b.y);};
        auto first=std::min_element(input.begin(),input.end(),less);
        std::rotate(input.begin(),first,input.end());
        if(less(input.back(),input[1])) std::reverse(input.begin()+1,input.end());
        return input;
    }
    static bool sameCycle(const Path& a,const Path& b) {
        const auto x=canonical(a),y=canonical(b);
        if(x.size()!=y.size()) return false;
        for(size_t i=0;i<x.size();++i) if(x[i].x!=y[i].x || x[i].y!=y[i].y) return false;
        return true;
    }
    static Point add(Point a,Point b) {return {a[0]+b[0],a[1]+b[1]};}
    static Point sub(Point a,Point b) {return {a[0]-b[0],a[1]-b[1]};}
    static Point mul(Point a,double v) {return {a[0]*v,a[1]*v};}
    static double cross(Point a,Point b) {return a[0]*b[1]-a[1]*b[0];}
    static double dot(Point a,Point b) {return a[0]*b[0]+a[1]*b[1];}
    static double length(Point a) {return std::sqrt(a[0]*a[0]+a[1]*a[1]);}
    static Point unit(Point a) {
        const double n=length(a);
        if(!std::isfinite(n) || n<=0) throw std::invalid_argument("path-region-degenerate-or-overflow-segment");
        return mul(a,1/n);
    }
    static Point normal(Point a) {return {-a[1],a[0]};}
    static bool equal(Point a,Point b) {return std::abs(a[0]-b[0])<coordPrecision && std::abs(a[1]-b[1])<coordPrecision;}
    static int dotSign(Point a,Point b) {
        const double fuzz=(length(a)+length(b))*epsilon;
        const double p1=a[0]*b[0],p2=-a[1]*b[1];
        return p1<=p2-fuzz ? -1 : p1<p2+fuzz ? 0 : 1;
    }
    static bool contains(Point a,Point b,Point p) {
        if(equal(a,b)) return equal(a,p);
        return std::abs(cross(sub(b,a),sub(p,a)))/length(sub(b,a))<coordPrecision &&
               dotSign(sub(p,a),sub(b,a))>=0 && dotSign(sub(p,b),sub(a,b))>=0;
    }
    static Ring realPoints(const Ring& input) {
        Ring output;
        size_t p=0;
        while(p<input.size()) {
            output.push_back(input[p++]);
            while(p<input.size() && equal(input[p],output.back())) ++p;
            if(p<input.size()) {
                size_t pn=p;
                while(++p<input.size()) {
                    while(p<input.size() && equal(input[p],input[pn])) ++p;
                    if(p==input.size() || !contains(output.back(),input[p],input[pn])) break;
                    pn=p;
                }
                --p;
            }
        }
        return output;
    }
    static void checkPoint(const Point& p,double grid) {
        for(double c:p) {
            const long double q=static_cast<long double>(c)/grid;
            if(!std::isfinite(q) || std::abs(q)>GeneralClipper::kCoordLimit)
                throw std::invalid_argument("path-region-coordinate-grid-range");
        }
    }
    static void shifted(const Ring& points,double start,double end,double width,int ncircle,Ring& output) {
        const double half=width*.5;
        size_t p=0,pp=1;
        bool first=true;
        while(pp<points.size()) {
            const size_t ppp=pp+1;
            const Point ed=unit(sub(points[pp],points[p]));
            const Point nd=mul(normal(ed),half);
            if(first) {
                first=false;
                if(ncircle>2) {
                    const double a0=pi/(2*ncircle),cd=std::cos(a0),sd=std::sin(a0);
                    const double c2=cd*cd-sd*sd,s2=2*cd*sd;
                    double c=cd,s=sd;
                    const Point edd=mul(ed,-start/cd),ndd=mul(nd,1/cd);
                    for(int i=0;i<ncircle/2;++i) {
                        output.push_back(add(points[p],add(mul(edd,c),mul(ndd,s))));
                        const double cc=c*c2-s*s2,ss=s*c2+c*s2;c=cc;s=ss;
                    }
                } else output.push_back(add(points[p],add(mul(ed,-start),nd)));
            }
            if(ppp==points.size()) {
                if(ncircle>2) {
                    const double a0=pi/(2*ncircle),cd=std::cos(a0),sd=std::sin(a0);
                    const double c2=cd*cd-sd*sd,s2=2*cd*sd;
                    double c=std::cos(a0*(ncircle-1)),s=std::sin(a0*(ncircle-1));
                    const Point edd=mul(ed,end/cd),ndd=mul(nd,1/cd);
                    for(int i=0;i<ncircle/2;++i) {
                        output.push_back(add(points[pp],add(mul(edd,c),mul(ndd,s))));
                        const double cc=c*c2+s*s2,ss=s*c2-c*s2;c=cc;s=ss;
                    }
                } else output.push_back(add(points[pp],add(mul(ed,end),nd)));
            } else {
                const Point eed=unit(sub(points[ppp],points[pp]));
                const Point nnd=mul(normal(eed),half);
                const double l1max=length(nd),l2max=length(nnd);
                const double l1min=-length(sub(points[pp],points[p]))-l1max;
                const double l2min=-length(sub(points[ppp],points[pp]))-l2max;
                const double dv=cross(ed,eed);
                if(std::abs(dv)>epsilon) {
                    const double l1=cross(sub(nnd,nd),eed)/dv;
                    const double l2=cross(sub(nd,nnd),ed)/dv;
                    if(l1<l1min-epsilon || l2<l2min-epsilon) {
                        output.push_back(add(points[pp],nd));output.push_back(points[pp]);output.push_back(add(points[pp],nnd));
                    } else if(l1<l1max+epsilon && l2<l2max+epsilon) {
                        output.push_back(add(points[pp],add(nd,mul(ed,l1))));
                    } else {
                        output.push_back(add(points[pp],add(nd,mul(ed,std::min(l1max,l1)))));
                        output.push_back(add(points[pp],sub(nnd,mul(eed,std::min(l2max,l2)))));
                    }
                    p=pp;
                } else if(dot(ed,eed)<-epsilon) {
                    output.push_back(add(points[pp],add(nd,mul(ed,half))));
                    output.push_back(add(points[pp],sub(nnd,mul(eed,half))));
                    p=pp;
                }
            }
            pp=ppp;
        }
    }
};
}}
#endif
