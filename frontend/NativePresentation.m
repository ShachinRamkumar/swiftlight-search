#import "NativeUIAdapter.h"
#import <math.h>

@implementation PanelPresentation
+ (void)resetWindow:(NSWindow *)window {
    window.alphaValue = 1;
}

+ (CAAnimationGroup *)scaleAnimationForOpening:(BOOL)opening collapsed:(BOOL)collapsed {
    CASpringAnimation *scale = [self springWithDuration:opening ? 0.35 : 0.3 bounce:opening ? 0.2 : 0];
    scale.keyPath = @"transform";
    CATransform3D from = opening ? CATransform3DMakeScale(0.94, 0.94, 1) : CATransform3DIdentity;
    CATransform3D to = opening ? CATransform3DIdentity : CATransform3DMakeScale(1.12, collapsed ? 0.95 : 1.12, 1);
    scale.fromValue = [NSValue valueWithCATransform3D:from];
    scale.toValue = [NSValue valueWithCATransform3D:to];

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scale];
    group.duration = scale.settlingDuration;
    return group;
}

+ (CASpringAnimation *)springWithDuration:(double)duration bounce:(double)bounce {
    CASpringAnimation *spring = [CASpringAnimation animation];
    spring.mass = 1;
    spring.stiffness = pow(2 * M_PI / duration, 2);
    spring.damping = 4 * M_PI * (1 - bounce) / duration;
    spring.duration = spring.settlingDuration;
    return spring;
}

+ (void)animateWindow:(NSWindow *)window
              opening:(BOOL)opening
             duration:(double)duration
           completion:(void (^)(void))completion {
    CABasicAnimation *alpha = [CABasicAnimation animation];
    alpha.duration = duration;
    alpha.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    window.animations = @{@"alphaValue": alpha};
    window.alphaValue = opening ? 0 : 1;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration;
        context.allowsImplicitAnimation = YES;
        window.animator.alphaValue = opening ? 1 : 0;
    } completionHandler:completion];
}
@end
