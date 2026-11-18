#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import "SPLiveProcessor.h"

static CVPixelBufferRef frame(int offset) {
    CVPixelBufferRef b=nullptr;
    CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&b);
    CVPixelBufferLockBaseAddress(b,0);
    auto *p=(uint8_t *)CVPixelBufferGetBaseAddress(b); size_t stride=CVPixelBufferGetBytesPerRow(b);
    for(int y=0;y<720;y++) for(int x=0;x<1280;x++) {
        uint8_t v=(x>400+offset && x<600+offset && y>200 && y<500)?220:30;
        auto *pixel=p+y*stride+x*4; pixel[0]=pixel[1]=pixel[2]=v;pixel[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(b,0);return b;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc!=2 || !dlopen(argv[1],RTLD_NOW|RTLD_GLOBAL)) { fprintf(stderr,"Cannot load built processor: %s\n",dlerror());return 2; }
        [NSApplication sharedApplication];
        SPLiveProcessor *p=[NSClassFromString(@"SPLiveProcessor") new];
        [p adoptSourceGeneration:7];
        SPLivePlanRequest *r=[NSClassFromString(@"SPLivePlanRequest") new];
        r.requestID=7;r.captureSourceKind=SPLiveCaptureSourceKindCaptureCard;
        r.interpolationEnabled=YES;r.engineID=@"apple.lowlatency";r.modelID=@"vt.llfi.temporal.1";
        r.qualityID=@"normal";r.quality=1;r.rateKind=SPLiveRateMultiplier;r.multiplier=2;
        r.captureCapFPS=60;r.displayRefreshHz=60;r.outputWidth=1280;r.outputHeight=720;
        [p setRawCadenceRefreshHz:60 captureLimit:60 displayID:0];[p updateRequest:r];
        CVPixelBufferRef b=frame(0);[p pushPixelBuffer:b ptsNum:0 ptsDen:30 host:mach_absolute_time() generation:7];CVPixelBufferRelease(b);
        for(int i=0;i<1500 && !p.resolvedPlan.committed && !p.resolvedPlan.unavailableReason.length;i++) usleep(10000);
        for(int i=1;i<100;i++) {
            int64_t host=mach_absolute_time();
            [p noteRawCapturePTSNum:i*2 ptsDen:60 host:host width:1280 height:720 generation:7];
            b=frame(i%20);[p pushPixelBuffer:b ptsNum:i ptsDen:30 host:host generation:7];CVPixelBufferRelease(b);
            usleep(16667);
            [p noteRawCapturePTSNum:i*2+1 ptsDen:60 host:mach_absolute_time() width:1280 height:720 generation:7];
            usleep(16667);
        }
        NSDictionary *s=p.stats;
        BOOL ok=p.resolvedPlan.committed && p.resolvedPlan.interpolationActive && ![s[@"nativeBudgetActive"] boolValue] && [s[@"delayMs"] doubleValue]<80 && [s[@"syntheticOK"] intValue]>0;
        NSDictionary *report=@{@"ok":@(ok),@"committed":@(p.resolvedPlan.committed),@"interpolationActive":@(p.resolvedPlan.interpolationActive),@"delayMs":s[@"delayMs"]?:@-1,@"generated":s[@"syntheticOK"]?:@0,@"error":p.resolvedPlan.unavailableReason?:@"",@"scope":@"Synthetic 720p 30fps direct-card request through real Apple inference; no camera, audio, window or physical presentation."};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        [p stop];return ok?0:1;
    }
}
