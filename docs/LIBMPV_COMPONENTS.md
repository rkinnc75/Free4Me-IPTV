# Custom libmpv — full enabled-component reference
_FFmpeg 6.0; flavor: --enable-decoders/demuxers/parsers/protocols/filters/bsfs + muxer allowlist (mp4/mov/matroska/mpegts/adts/mp3/flac/wav), --disable-gpl --disable-nonfree. Names match `ffmpeg -filters/-decoders/...`. See [CUSTOM_LIBMPV.md](./CUSTOM_LIBMPV.md) for the overview._

## FILTERS (435)

a3dscope,abench,abitscope,acompressor,acontrast,acopy,acrossfade,acrossover,acrusher,acue,addroi,ade
click,adeclip,adecorrelate,adelay,adenorm,aderivative,adrawgraph,adrc,adynamicequalizer,adynamicsmoo
th,aecho,aemphasis,aeval,aevalsrc,aexciter,afade,afdelaysrc,afftdn,afftfilt,afifo,afir,afirsrc,aform
at,afreqshift,afwtdn,agate,agraphmonitor,ahistogram,aiir,aintegral,ainterleave,alatency,alimiter,all
pass,allrgb,allyuv,aloop,alphaextract,alphamerge,amerge,ametadata,amix,amovie,amplify,amultiply,aneq
ualizer,anlmdn,anlmf,anlms,anoisesrc,anull,anullsink,anullsrc,apad,aperms,aphasemeter,aphaser,aphase
shift,apsyclip,apulsator,arealtime,aresample,areverse,arnndn,asdr,asegment,aselect,asendcmd,asetnsam
ples,asetpts,asetrate,asettb,ashowinfo,asidedata,asoftclip,aspectralstats,asplit,astats,astreamselec
t,asubboost,asubcut,asupercut,asuperpass,asuperstop,atadenoise,atempo,atilt,atrim,avectorscope,avgbl
ur,avsynctest,axcorrelate,backgroundkey,bandpass,bandreject,bass,bbox,bench,bilateral,biquad,bitplan
enoise,blackdetect,blend,blockdetect,blurdetect,bm3d,bwdif,cas,cellauto,channelmap,channelsplit,chor
us,chromahold,chromakey,chromanr,chromashift,ciescope,codecview,color,colorbalance,colorchannelmixer
,colorchart,colorcontrast,colorcorrect,colorhold,colorize,colorkey,colorlevels,colormap,colorspace,c
olorspectrum,colortemperature,compand,compensationdelay,concat,convolution,convolve,copy,coreimage,c
oreimagesrc,corr,crop,crossfeed,crystalizer,cue,curves,datascope,dblur,dcshift,dctdnoiz,deband,deblo
ck,decimate,deconvolve,dedot,deesser,deflate,deflicker,dejudder,derain,deshake,despill,detelecine,di
aloguenhance,dilation,displace,dnn_classify,dnn_detect,dnn_processing,doubleweave,drawbox,drawgraph,
drawgrid,drmeter,dynaudnorm,earwax,ebur128,edgedetect,elbg,entropy,epx,equalizer,erosion,estdif,expo
sure,extractplanes,extrastereo,fade,feedback,fftdnoiz,fftfilt,field,fieldhint,fieldmatch,fieldorder,
fifo,fillborders,firequalizer,flanger,floodfill,format,fps,framepack,framerate,framestep,freezedetec
t,freezeframes,gblur,geq,gradfun,gradients,graphmonitor,grayworld,greyedge,guided,haas,haldclut,hald
clutsrc,hdcd,headphone,hflip,highpass,highshelf,hilbert,histogram,hqx,hstack,hsvhold,hsvkey,hue,hues
aturation,hwdownload,hwmap,hwupload,hysteresis,identity,idet,il,inflate,interleave,join,kirsch,lagfu
n,latency,lenscorrection,life,limitdiff,limiter,loop,loudnorm,lowpass,lowshelf,lumakey,lut,lut1d,lut
2,lut3d,lutrgb,lutyuv,mandelbrot,maskedclamp,maskedmax,maskedmerge,maskedmin,maskedthreshold,maskfun
,mcompand,median,mergeplanes,mestimate,metadata,midequalizer,minterpolate,mix,monochrome,morpho,movi
e,msad,multiply,negate,nlmeans,noformat,noise,normalize,null,nullsink,nullsrc,oscilloscope,overlay,p
ad,pal100bars,pal75bars,palettegen,paletteuse,pan,perms,photosensitivity,pixdesctest,pixelize,pixsco
pe,premultiply,prewitt,pseudocolor,psnr,qp,random,readeia608,readvitc,realtime,remap,removegrain,rem
ovelogo,replaygain,reverse,rgbashift,rgbtestsrc,roberts,rotate,scale,scale2ref,scdet,scharr,scroll,s
egment,select,selectivecolor,sendcmd,separatefields,setdar,setfield,setparams,setpts,setrange,setsar
,settb,shear,showcqt,showcwt,showfreqs,showinfo,showpalette,showspatial,showspectrum,showspectrumpic
,showvolume,showwaves,showwavespic,shuffleframes,shufflepixels,shuffleplanes,sidechaincompress,sidec
haingate,sidedata,sierpinski,signalstats,silencedetect,silenceremove,sinc,sine,siti,smptebars,smpteh
dbars,sobel,spectrumsynth,speechnorm,split,sr,ssim,ssim360,stereotools,stereowiden,streamselect,supe
requalizer,surround,swaprect,swapuv,tblend,telecine,testsrc,testsrc2,thistogram,threshold,thumbnail,
tile,tiltshelf,tlut2,tmedian,tmidequalizer,tmix,tonemap,tpad,transpose,treble,tremolo,trim,unpremult
iply,unsharp,untile,v360,varblur,vectorscope,vflip,vfrdet,vibrance,vibrato,vif,vignette,virtualbass,
vmafmotion,volume,volumedetect,vstack,w3fdif,waveform,weave,xbr,xcorrelate,xfade,xmedian,xstack,yadi
f,yaepblur,yuvtestsrc,zoompan


## DECODERS (505)

aac,aac_at,aac_fixed,aac_latm,aasc,ac3,ac3_at,ac3_fixed,acelp_kelvin,adpcm_4xm,adpcm_adx,adpcm_afc,a
dpcm_agm,adpcm_aica,adpcm_argo,adpcm_ct,adpcm_dtk,adpcm_ea,adpcm_ea_maxis_xa,adpcm_ea_r1,adpcm_ea_r2
,adpcm_ea_r3,adpcm_ea_xas,adpcm_g722,adpcm_g726,adpcm_g726le,adpcm_ima_acorn,adpcm_ima_alp,adpcm_ima
_amv,adpcm_ima_apc,adpcm_ima_apm,adpcm_ima_cunning,adpcm_ima_dat4,adpcm_ima_dk3,adpcm_ima_dk4,adpcm_
ima_ea_eacs,adpcm_ima_ea_sead,adpcm_ima_iss,adpcm_ima_moflex,adpcm_ima_mtf,adpcm_ima_oki,adpcm_ima_q
t,adpcm_ima_qt_at,adpcm_ima_rad,adpcm_ima_smjpeg,adpcm_ima_ssi,adpcm_ima_wav,adpcm_ima_ws,adpcm_ms,a
dpcm_mtaf,adpcm_psx,adpcm_sbpro_2,adpcm_sbpro_3,adpcm_sbpro_4,adpcm_swf,adpcm_thp,adpcm_thp_le,adpcm
_vima,adpcm_xa,adpcm_xmd,adpcm_yamaha,adpcm_zork,agm,aic,alac,alac_at,alias_pix,als,amr_nb_at,amrnb,
amrwb,amv,anm,ansi,anull,apac,ape,apng,aptx,aptx_hd,arbc,argo,ass,asv1,asv2,atrac1,atrac3,atrac3al,a
trac3p,atrac3pal,atrac9,aura,aura2,av1,avrn,avrp,avs,avui,ayuv,bethsoftvid,bfi,bink,binkaudio_dct,bi
nkaudio_rdft,bintext,bitpacked,bmp,bmv_audio,bmv_video,bonk,brender_pix,c93,cavs,cbd2_dpcm,ccaption,
cdgraphics,cdtoons,cdxl,cfhd,cinepak,clearvideo,cljr,cllc,comfortnoise,cook,cpia,cri,cscd,cyuv,dca,d
ds,derf_dpcm,dfa,dfpwm,dirac,dnxhd,dolby_e,dpx,dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar,dsi
cinaudio,dsicinvideo,dss_sp,dst,dvaudio,dvbsub,dvdsub,dvvideo,dxa,dxtory,dxv,eac3,eac3_at,eacmv,eama
d,eatgq,eatgv,eatqi,eightbps,eightsvx_exp,eightsvx_fib,escape124,escape130,evrc,exr,fastaudio,ffv1,f
fvhuff,ffwavesynth,fic,fits,flac,flashsv,flashsv2,flic,flv,fmvc,fourxm,fraps,frwu,ftr,g2m,g723_1,g72
9,gdv,gem,gif,gremlin_dpcm,gsm,gsm_ms,gsm_ms_at,h261,h263,h263i,h263p,h264,hap,hca,hcom,hdr,hevc,hnm
4_video,hq_hqa,hqx,huffyuv,hymt,iac,idcin,idf,iff_ilbm,ilbc,ilbc_at,imc,imm4,imm5,indeo2,indeo3,inde
o4,indeo5,interplay_acm,interplay_dpcm,interplay_video,ipu,jacosub,jpeg2000,jpegls,jv,kgv1,kmvc,laga
rith,loco,lscr,m101,mace3,mace6,magicyuv,mdec,media100,metasound,microdvd,mimic,misc4,mjpeg,mjpegb,m
lp,mmvideo,mobiclip,motionpixels,movtext,mp1,mp1_at,mp1float,mp2,mp2_at,mp2float,mp3,mp3_at,mp3adu,m
p3adufloat,mp3float,mp3on4,mp3on4float,mpc7,mpc8,mpeg1video,mpeg2video,mpeg4,mpegvideo,mpl2,msa1,msc
c,msmpeg4v1,msmpeg4v2,msmpeg4v3,msnsiren,msp2,msrle,mss1,mss2,msvideo1,mszh,mts2,mv30,mvc1,mvc2,mvdv
,mvha,mwsc,mxpeg,nellymoser,notchlc,nuv,on2avc,opus,paf_audio,paf_video,pam,pbm,pcm_alaw,pcm_alaw_at
,pcm_bluray,pcm_dvd,pcm_f16le,pcm_f24le,pcm_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_lxf,pcm_mulaw,pc
m_mulaw_at,pcm_s16be,pcm_s16be_planar,pcm_s16le,pcm_s16le_planar,pcm_s24be,pcm_s24daud,pcm_s24le,pcm
_s24le_planar,pcm_s32be,pcm_s32le,pcm_s32le_planar,pcm_s64be,pcm_s64le,pcm_s8,pcm_s8_planar,pcm_sga,
pcm_u16be,pcm_u16le,pcm_u24be,pcm_u24le,pcm_u32be,pcm_u32le,pcm_u8,pcm_vidc,pcx,pfm,pgm,pgmyuv,pgssu
b,pgx,phm,photocd,pictor,pixlet,pjs,png,ppm,prores,prosumer,psd,ptx,qcelp,qdm2,qdm2_at,qdmc,qdmc_at,
qdraw,qoi,qpeg,qtrle,r10k,r210,ra_144,ra_288,ralf,rasc,rawvideo,realtext,rka,rl2,roq,roq_dpcm,rpza,r
scc,rv10,rv20,rv30,rv40,s302m,sami,sanm,sbc,scpr,screenpresso,sdx2_dpcm,sga,sgi,sgirle,sheervideo,sh
orten,simbiosis_imx,sipr,siren,smackaud,smacker,smc,smvjpeg,snow,sol_dpcm,sonic,sp5x,speedhq,speex,s
rgc,srt,ssa,stl,subrip,subviewer,subviewer1,sunrast,svq1,svq3,tak,targa,targa_y216,tdsc,text,theora,
thp,tiertexseqvideo,tiff,tmv,truehd,truemotion1,truemotion2,truemotion2rt,truespeech,tscc,tscc2,tta,
twinvq,txd,ulti,utvideo,v210,v210x,v308,v408,v410,vb,vble,vbn,vc1,vc1image,vcr1,vmdaudio,vmdvideo,vm
nc,vnull,vorbis,vp3,vp4,vp5,vp6,vp6a,vp6f,vp7,vp8,vp9,vplayer,vqa,vqc,wady_dpcm,wavarc,wavpack,wbmp,
wcmv,webp,webvtt,wmalossless,wmapro,wmav1,wmav2,wmavoice,wmv1,wmv2,wmv3,wmv3image,wnv1,wrapped_avfra
me,ws_snd1,xan_dpcm,xan_wc3,xan_wc4,xbin,xbm,xface,xl,xma1,xma2,xpm,xsub,xwd,y41p,ylc,yop,yuv4,zero1
2v,zerocodec,zlib,zmbv


## DEMUXERS (343)

aa,aac,aax,ac3,ace,acm,act,adf,adp,ads,adx,aea,afc,aiff,aix,alp,amr,amrnb,amrwb,anm,apac,apc,ape,apm
,apng,aptx,aptx_hd,aqtitle,argo_asf,argo_brp,argo_cvg,asf,asf_o,ass,ast,au,av1,avi,avr,avs,avs2,avs3
,bethsoftvid,bfi,bfstm,bink,binka,bintext,bit,bitpacked,bmv,boa,bonk,brstm,c93,caf,cavsvideo,cdg,cdx
l,cine,codec2,codec2raw,concat,data,daud,dcstr,derf,dfa,dfpwm,dhav,dirac,dnxhd,dsf,dsicin,dss,dts,dt
shd,dv,dvbsub,dvbtxt,dxa,ea,ea_cdata,eac3,epaf,ffmetadata,filmstrip,fits,flac,flic,flv,fourxm,frm,fs
b,fwse,g722,g723_1,g726,g726le,g729,gdv,genh,gif,gsm,gxf,h261,h263,h264,hca,hcom,hevc,hls,hnm,ico,id
cin,idf,iff,ifv,ilbc,image2,image2_alias_pix,image2_brender_pix,image2pipe,image_bmp_pipe,image_cri_
pipe,image_dds_pipe,image_dpx_pipe,image_exr_pipe,image_gem_pipe,image_gif_pipe,image_hdr_pipe,image
_j2k_pipe,image_jpeg_pipe,image_jpegls_pipe,image_jpegxl_pipe,image_pam_pipe,image_pbm_pipe,image_pc
x_pipe,image_pfm_pipe,image_pgm_pipe,image_pgmyuv_pipe,image_pgx_pipe,image_phm_pipe,image_photocd_p
ipe,image_pictor_pipe,image_png_pipe,image_ppm_pipe,image_psd_pipe,image_qdraw_pipe,image_qoi_pipe,i
mage_sgi_pipe,image_sunrast_pipe,image_svg_pipe,image_tiff_pipe,image_vbn_pipe,image_webp_pipe,image
_xbm_pipe,image_xpm_pipe,image_xwd_pipe,ingenient,ipmovie,ipu,ircam,iss,iv8,ivf,ivr,jacosub,jv,kux,k
vag,laf,live_flv,lmlm4,loas,lrc,luodat,lvf,lxf,m4v,matroska,mca,mcc,mgsts,microdvd,mjpeg,mjpeg_2000,
mlp,mlv,mm,mmf,mods,moflex,mov,mp3,mpc,mpc8,mpegps,mpegts,mpegtsraw,mpegvideo,mpjpeg,mpl2,mpsub,msf,
msnwc_tcp,msp,mtaf,mtv,musx,mv,mvi,mxf,mxg,nc,nistsphere,nsp,nsv,nut,nuv,obu,ogg,oma,paf,pcm_alaw,pc
m_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_mulaw,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pc
m_s32le,pcm_s8,pcm_u16be,pcm_u16le,pcm_u24be,pcm_u24le,pcm_u32be,pcm_u32le,pcm_u8,pcm_vidc,pjs,pmp,p
p_bnk,pva,pvf,qcp,r3d,rawvideo,realtext,redspark,rka,rl2,rm,roq,rpl,rsd,rso,rtp,rtsp,s337m,sami,sap,
sbc,sbg,scc,scd,sdns,sdp,sdr2,sds,sdx,segafilm,ser,sga,shorten,siff,simbiosis_imx,sln,smacker,smjpeg
,smush,sol,sox,spdif,srt,stl,str,subviewer,subviewer1,sup,svag,svs,swf,tak,tedcaptions,thp,threedost
r,tiertexseq,tmv,truehd,tta,tty,txd,ty,v210,v210x,vag,vc1,vc1t,vividas,vivo,vmd,vobsub,voc,vpk,vplay
er,vqf,w64,wady,wav,wavarc,wc3,webm_dash_manifest,webvtt,wsaud,wsd,wsvqa,wtv,wv,wve,xa,xbin,xmd,xmv,
xvag,xwma,yop,yuv4mpegpipe


## PARSERS (58)

aac,aac_latm,ac3,adx,amr,av1,avs2,avs3,bmp,cavsvideo,cook,cri,dca,dirac,dnxhd,dolby_e,dpx,dvaudio,dv
bsub,dvd_nav,dvdsub,flac,ftr,g723_1,g729,gif,gsm,h261,h263,h264,hdr,hevc,ipu,jpeg2000,misc4,mjpeg,ml
p,mpeg4video,mpegaudio,mpegvideo,opus,png,pnm,qoi,rv30,rv40,sbc,sipr,tak,vc1,vorbis,vp3,vp8,vp9,webp
,xbm,xma,xwd


## PROTOCOLS (37)

async,cache,concat,concatf,crypto,data,fd,ffrtmphttp,file,ftp,gopher,gophers,hls,http,httpproxy,http
s,icecast,ipfs_gateway,ipns_gateway,md5,mmsh,mmst,pipe,prompeg,rtmp,rtmps,rtmpt,rtmpts,rtp,srtp,subf
ile,tcp,tee,tls,udp,udplite,unix

## Muxers (9, added v4.0.0)

`mp4`, `mov`, `matroska`, `mpegts`, `adts`, `mp3`, `flac`, `wav`, `latm`.

Enabled for recording container conversion (stream-copy `.ts` → MP4, MKV fallback),
TS timestamp repair (`mpegts`), and audio-only extraction. libavformat container
writers — no GPL/non-free dependency; LGPLv3 unchanged. Mux symbols exported in the
built `.so`.
