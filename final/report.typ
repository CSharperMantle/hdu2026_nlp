#import "@preview/ouset:0.2.0": ouset
#import "@preview/algorithmic:1.0.7"
#import algorithmic: algorithm-figure, style-algorithm

#import "../assets/hdu-report-typst/template/template.typ": *

#show: style-algorithm
#show: project.with(
  title: [
    杭州电子科技大学\
    《自然语言处理》\
    实验报告\
  ],
  subtitle: [基于依存树的自然语言三路合并],
  class: "计算机科学英才班",
  department: "卓越学院",
  authors: "鲍溶",
  author_id: "23060827",
  date: datetime.today(),
  cover_style: "hdu_report",
)

#set quote(block: true)
#show link: underline

#toc()

#pagebreak()

= 引言

= 相关工作

= 实验方法

= 实现

= 效果评价

= 展望与总结

= 源代码

本实验完整源代码可从 #link("https://github.com/CSharperMantle/semdiff3") 获取。

#pagebreak()

#bibliography("bib.bib", style: "gb-7714-2015-numeric")
