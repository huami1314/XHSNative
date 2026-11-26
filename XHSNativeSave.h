//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/26
//
#import <UIKit/UIKit.h>

// 评论区的无水印保存。评论的视频和实况由服务器渲染带水印的版本，图片在本地画水印，
// 这里改成用评论里原始的地址：视频、实况交给小红书私信模块现成的保存，图片直接存原图数据（动图保留动画）
@interface XHSNativeSave : NSObject

// 记下加载过的评论，保存时按评论 id 找回原始地址
+ (void)rememberComment:(id)comment;

// 返回 NO 表示没找到原始地址，交回小红书原来的流程
+ (BOOL)saveCommentVideoWithCommentId:(NSString *)commentId index:(NSInteger)index;
+ (BOOL)saveCommentLivePhotoWithCommentId:(NSString *)commentId videoId:(NSString *)videoId imageURL:(NSString *)imageURL;
+ (BOOL)saveCommentImageWithURL:(NSString *)url completion:(void (^)(BOOL success))completion;

// 视频流里左右滑的图集笔记：屏幕中间这篇的图集视图，不是图集返回 nil
+ (UIView *)slidesOfNote:(NSString *)noteId;
// 存当前这一张或全部，实况存成实况，静态图存原图。completion 在主线程
+ (void)saveSlides:(UIView *)slides all:(BOOL)all completion:(void (^)(BOOL success))completion;

@end
