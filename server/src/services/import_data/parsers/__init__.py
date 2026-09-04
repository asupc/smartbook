"""Parser 实现 —— 仅两条路径:smartbook(自家格式)/ generic(全集 alias)。

支付宝 / 微信 / 银行账单等现实文件都走 generic;之前的 alipay/wechat 分叉
被合并到 generic 一张全集 alias 表里(见 parser.py 注释)。"""
from .generic import GenericParser
from .smartbook import SmartBookParser

__all__ = ["SmartBookParser", "GenericParser"]
