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
  date: datetime(year: 2026, month: 6, day: 23),
  cover_style: "hdu_report",
)

#set quote(block: true)
#show link: underline

#toc()

#pagebreak()

= 引言

在协同编辑场景中，同一文档经常被多人独立修改，而后需要将各分支的修改合并为统一的最终版本。传统的三路合并工具基于文本行进行操作，通过最长公共子序列算法逐行比较三个版本以确定冲突区域。这种方法对源代码的行级编辑较为有效，但对于自然语言文本则存在根本性的局限：自然语言的句子内部有丰富的语法结构，行级合并完全无法感知这种结构，导致许多本可自动融合的编辑被误报为冲突。

考虑下列场景，后文称为“餐厅场景”：

#quote(block: true)[
  $O$: #h(1em) I drove to the restaurant in the afternoon.

  $A$: #h(1em) I drove to the restaurant in the morning.

  $B$: #h(1em) In the afternoon, I drove to the restaurant.
]

原始版本 $O$ 包含一个时间状语“in the afternoon”。Alice 将其中的名词“afternoon”替换为“morning”，修改了时间表述的内容。Bob 则将整个时间状语前移至句首，调整了语序。从语义上看，这两处修改分别作用于不同的维度：一处更改用词，一处调整词序，应当可以组合共存，从而得到“In the morning, I drove to the restaurant.”然而，diff3 在逐行对比时发现“afternoon”附近的文本在两个分支中都发生了变化，将其判定为冲突，并交由人工处理。

这一困境的根源在于，行级表示将语义角色和表层词序耦合在一起，无法区分两类不同性质的编辑。依存句法树提供了解决这一问题的理论基础：句子的结构可以分解为依存关系，即支配关系与依存关系类型，与表层词序，即同一父节点下兄弟之间的先后顺序，两个正交维度，$A$ 的用词更改与 $B$ 的语序调整恰好作用于不同的维度，因而可以组合共存。二者的正交性使得更新编辑与移动编辑可以组合共存。

本实验设计并实现了一个基于依存句法树的自然语言语义三路合并原型系统 semdiff3。给定原始版本 $O$ 及两份修改版本 $A$ 与 $B$，semdiff3 执行以下流水线：首先使用 Stanford Stanza@qi2020stanza Universal Dependencies（通用依存，UD）流水线对三个句子进行依存句法分析，生成依存树，然后对依存树进行规范化处理，得到位置无关的规范化树表示，接着执行受 Mergiraf@delpeuch2023mergiraf 启发的两阶段树匹配，在 $O$ 与 $A$、$O$ 与 $B$ 以及 $A$ 与 $B$ 之间建立节点对应关系；基于匹配结果构建跨版本的等价类；遍历等价类计算各分支相对于 $O$ 的结构化编辑，包括更新、移动、插入、删除；最后通过决策表对两侧编辑进行合并，并将合并结果渲染为文本。

本实验旨在探索将结构化合并技术从源代码领域移植至自然语言领域的可行性，验证依存树级别的两维度分解是否能够有效解决行级合并无法处理的复合编辑场景。

= 相关工作

== 三路合并的理论基础

三路合并解决的核心问题可以抽象为以下表述：给定一个对象，如待合并的文档，及其三个状态：原始状态 $O$ 及两份修改状态 $A$ 与 $B$，产生产生一个同时纳入 $A$ 与 $B$ 中所有合理修改的新状态。对象由一系列原子以特定的组合方式构成，如文本行、语法树节点、依存树节点等。

三路合并的一般流程如@figure:diff3-general-flow 所示，包含五个步骤：

+ 解析：将各状态按所选原子粒度进行结构化拆解；
+ 双路作差：分别计算 $O$ 与 $A$、$O$ 与 $B$ 在原子级别的差异；
+ 对齐：将前一步得到的两组差异进行跨版本的对齐，形成三路编辑块；
+ 合并：对每个编辑块执行合并决策；
+ 渲染：将合并后的编辑序列还原为最终文档。

#img(
  image("assets/general-flow.png"),
  caption: [一般三路合并流程],
) <figure:diff3-general-flow>

== diff3(1)

diff3(1) 基于文本行序列进行三路合并，是 UNIX 系统提供的标准三路合并工具，也是如 RCS、Git 等基于文本的版本控制系统中最常用的合并算法。给定原始文件 $O$ 及两份修改 $A$ 与 $B$，diff3 首先通过最长公共子序列算法分别计算 $O$ 与 $A$、$O$ 与 $B$ 之间基于行的差异，然后将两组差异对齐为编辑块，最后对编辑块执行三路决策：仅在一侧发生变化的块自动予以接受，两侧变化相同的块自动接受，两侧变化不同的块则标记为冲突。

diff3(1) 虽然作为序列空间上的操作具有很差的数学性质@khanna2007diff3，但其实现简单、算法简洁，在源代码的行级合并中较为实用，但对于自然语言文本则存在根本局限。自然语言中，一个句子的内部结构远比文本行丰富：同一个语义内容可以有不同的语序，同一处修改可能同时涉及用词替换和语序调整。diff3 完全无法感知这些结构信息，它将每一行视为不可分割的原子单元，因此两个分支对同一文本区域的不同操作都会被判定为冲突，即使这些操作涉及不同的语法维度。引言中 餐厅场景的两个编辑，即内容更新与语序调整，在 diff3 下被误报为冲突，正是这一局限的典型表现。

== Mergiraf

Mergiraf@delpeuch2023mergiraf 是面向抽象语法树（AST）的结构化合并工具。与 diff3 不同，Mergiraf 使用 tree-sitter 解析器将源文件解析为抽象语法树，然后在 AST 级别进行匹配与合并。其核心方法包括：通过双亲--孩子--后继（PCS，parent-child-successor）三元组表示树的结构信息，采用两阶段匹配，即自顶向下的结构键匹配与自底向上的 Dice 系数相似度匹配，建立节点对应关系，构建跨版本的等价类，最后基于等价类进行编辑的自动合并。

Mergiraf 的设计直接影响了本实验。本实验的等价类构造方法参考了 Mergiraf 中 `class_mapping` 的一致性校验逻辑：当 $A$ 与 $B$ 之间的匹配试图桥接两个不同的 $O$ 主导的等价类时，该匹配被丢弃，以防止矛盾的映射关系导致不合理的编辑推断。此外，Mergiraf 的两阶段匹配策略，特别是 Dice 阈值的设定和自顶向下同构匹配的优先级排序，也被本实验的匹配模块所采用。本实验的关键扩展在于将这一结构化合并方法论从代码 AST 迁移到了自然语言的依存句法树上。

与 Mergiraf 相关的还有两项重要工作。GumTree@falleri2014gumtree 提出了两阶段树匹配算法的完整框架，包括结构键的定义、自顶向下同构匹配的优先队列调度以及自底向上匹配的候选搜索策略。本实验的匹配模块直接遵循 GumTree 的算法设计，但将节点标签从代码 AST 的语法类型替换为通用词性（UPOS）标签，将节点文本从代码标识符替换为自然语言的词形。Spork@larsen2023spork 将 PCS 三元组抽象用于 Java AST 的三路结构化合并，证明了三元组分解可以有效支持合并决策。本实验在此基础上进一步将 PCS 思想扩展为依存三元组与顺序三元组两个正交维度，以适应自然语言中语义角色与表层词序分离的特殊需求。

== betterprompt

betterprompt@nimai2023betterprompt 是一个直接面向自然语言的三路合并工具。它的基本思路是将文本分割为语义单元，即句子或段落，通过词嵌入表示计算单元间的相似度，利用序列动态规划进行跨版本对齐，然后对结果应用三路决策表：保留、替换、插入、删除或冲突。对于两个分支都发生变化的单元，betterprompt 使用基于 LCS 的词级差异作为回退策略。

betterprompt 与本实验代表了两种不同的技术路线。betterprompt 在语义单元级别操作，通过嵌入表示捕捉语义相似度，适合段落级的合并场景。本实验则在句子内部进行依存树级别的匹配与合并，能够更精细地处理单词级别的编辑，特别是能够识别和组合作用于不同语法维度的编辑，例如更新与移动。两种方法各有侧重：betterprompt 的优势在于处理跨句子的变动，本实验的优势在于在句子内部进行结构感知的合并。

== 差异分析与句子融合

在更广泛的自然语言语义差异分析方面，Vamvas 和 Sennrich@vamvas2023towards 提出了一个面向跨文档 token 级语义差异识别的无监督方法，为本实验提供了评估分类框架的参考。句子融合方面，Barzilay 和 McKeown@barzilay2005sentence 研究了如何将多个句子的依存树融合为一个流畅的句子，其重排与词汇选择策略对结构化渲染步骤有一定的参考意义。但句子融合处理的是多源信息选择性组合问题，而非三路版本合并中的冲突消解问题。betterprompt 和本实验分别在句子级和词级两个粒度上探索了自然语言三路合并问题，Vamvas 与 Sennrich 的工作为语义差异评估提供了方法论基础，上述工作共同构成了本实验的研究背景。

= 实验方法

本实验的合并流水线包括六个主要步骤：依存句法分析与规范化、两阶段树匹配、等价类构建、编辑计算、合并决策以及文本渲染。下面逐一阐述各步骤的设计思路与技术细节。

== 依存句法分析与规范化

给定句子 $O$、$A$、$B$，首先使用 Stanza@qi2020stanza 的通用依存流水线，包含分词、词性分析、词根分析、依存关系解析四个模块，分别生成三棵依存句法树。每棵依存树由若干节点组成，每个节点对应一个词，包含词形、词性标签、依存关系标签等信息，节点之间通过有向边 `head` #sym.arrow.r `dependent` 连接。

本方法的核心思路在于，依存树所编码的结构信息可以分解为两个正交的维度。第一是依存三元组 `(governor, deprel, dependent)`，它编码了语义角色结构，即各节点间的支配关系与依存关系类型。第二是顺序三元组 `(governor, child, successor)`，它编码了表层词序，即在同一父节点下各子节点之间的先后顺序。这种两维度分解的意义在于：一个分支可能在依存三元组上修改内容，例如将“afternoon”改为“morning”，而不改变顺序三元组，另一个分支可能在顺序三元组上调整语序，例如将时间状语前移，而不改变依存三元组。由于两类编辑作用于不同的维度，它们可以组合共存而不产生冲突。

原始的依存树中，子节点的顺序直接反映表层词序。为了进行位置无关的匹配，需要将原始树进行规范化。规范化处理将各节点的子节点按 `(deprel, lowercase text)` 排序，使得同一语法角色的子节点在不同版本中得到稳定的相对顺序。标点节点予以保留，因为标点的插入和删除可能是有效的编辑；原始词形也予以保留，用于后续的编辑检测。规范化树仅在匹配阶段使用，最终的文本渲染仍参照原始树。

== 两阶段树匹配

树匹配的目标是在两棵树之间建立节点级别的对应关系。本实验采用受 GumTree@falleri2014gumtree 启发的两阶段匹配策略，依次执行自顶向下匹配和自底向上匹配。程序员在手动处理冲突时，会先扫视文档并忽略所有未发生改变的内容，剪枝后找到变更内容的最内层容器，最后才仔细观察具体发生哪些变更，进行精细匹配；GumTree 的两遍算法思路便由此而来。

自顶向下阶段按结构键进行匹配。每个节点的结构键定义为递归元组 `(label, text, relation, child_keys...)`，其中 `child_keys` 为各子节点的结构键。两棵树中结构键完全相同的子树被认为是同构的，直接建立节点级别的映射。匹配按子树高度降序进行，优先匹配较大的同构块。

自底向上阶段处理自顶向下阶段未匹配的节点。首先强制匹配两棵树的根节点。然后按后序遍历未匹配节点，对每个候选节点对计算裁剪子树上的 Dice 系数。Dice 系数定义为 $2|M| / (|S_1| + |S_2|)$，其中 $|M|$ 为两子树中已建立映射的节点数，$|S_1|$ 和 $|S_2|$ 为两子树的规模。当 Dice 系数超过阈值 0.5 时接受该对匹配，此阈值参照了 GumTree@falleri2014gumtree 的设定。对仍然未决的节点对，使用 Zhang-Shasha 树编辑距离算法@zhang1989simple 进行最优对齐，树编辑距离的节点替换代价以二元组 Jaccard 相似度作为软性文本替换代价。子树规模超过 $"SIZE_THRESHOLD" = 1000$ 时跳过树编辑距离计算，仅依赖 Dice 系数进行决策。

匹配过程执行三次：$O$ 与 $A$、$O$ 与 $B$ 分别产生直接匹配，然后以 $O$ #sym.arrow.l.r $A$ 与 $O$ #sym.arrow.l.r $B$ 的传递闭包作为初始种子执行 $A$ 与 $B$ 的匹配。

== 等价类构建

将三对匹配结果合并为跨版本的等价类。每个等价类以 $O$、$A$、$B$ 中优先级别最高的节点作为领导者，优先级为 $O > A > B$，将其他版本中的对应节点作为成员。从 $O$ #sym.arrow.l.r $A$ 和 $O$ #sym.arrow.l.r $B$ 推导出的 $A$ #sym.arrow.l.r $B$ 匹配用于增强等价类的完整性，但若 $A$ #sym.arrow.l.r $B$ 匹配试图桥接两个不同的 $O$ 主导的等价类，则该匹配被丢弃。一致性校验思路参考了 Mergiraf，详见相关工作，以防止矛盾的映射关系导致不合理的编辑推断。

== 编辑计算

遍历等价类，分别从 $O$ 到 $A$ 和从 $O$ 到 $B$ 计算结构化编辑序列。每个等价类的处理分四种情况：若类中同时包含 $O$ 节点和侧版本节点，即分支 $A$ 或 $B$ 中的版本，则进一步检查词形是否变化以决定是否产生”更新编辑”，检查后继节点是否变化以决定是否产生”移动编辑”；若 $O$ 节点在侧版本中无对应节点且非根节点，则产生”删除编辑”；若侧版本节点在 $O$ 中无对应节点且非根节点，则产生”插入编辑”；不属于任何等价类的孤立节点作相应处理。

== 合并决策

对每个基准节点，将来自 $A$ 侧和 $B$ 侧的两组编辑集合输入决策表。决策逻辑如@algo:merge-decision 所示，其核心原则是仅一侧有编辑时直接接受，两侧编辑相同时接受一次，两侧编辑作用于不同维度时组合接受，例如一侧更新内容、一侧移动位置，两侧编辑作用于相同维度但内容不同时，报告冲突。

#algorithm-figure(
  [三路合并决策表],
  supplement: [算法],
  vstroke: .5pt + luma(200),
  {
    import algorithmic: *
    Function(
      "Resolve-Node",
      ($n_O$, $e_A$, $e_B$),
      {
        Comment[两侧均无编辑：跳过]
        If($"op"(e_A) = "none" and "op"(e_B) = "none"$, { Return[$"nil"$] })
        Comment[单侧编辑：接受]
        If($"op"(e_A) = "none" and "op"(e_B) != "none"$, { Return[$e_B$] })
        If($"op"(e_A) != "none" and "op"(e_B) = "none"$, { Return[$e_A$] })
        Comment[两侧相同：接受]
        If($e_A = e_B$, { Return[$e_A$] })
        Comment[不同维度：组合接受]
        If($"op"(e_A) = "update" and "op"(e_B) = "move"$, { Return[($e_A$, $e_B$)] })
        If($"op"(e_A) = "move" and "op"(e_B) = "update"$, { Return[($e_A$, $e_B$)] })
        Comment[更新--更新冲突]
        If($"op"(e_A) = "update" and "op"(e_B) = "update" and "text"(e_A) != "text"(e_B)$, { Return[("conflict")] })
        Comment[删除--更新冲突]
        If($"op"(e_A) = "delete" and "op"(e_B) != "delete"$, { Return[("conflict")] })
        If($"op"(e_B) = "delete" and "op"(e_A) != "delete"$, { Return[("conflict")] })
        Comment[两侧均删除：接受]
        If($"op"(e_A) = "delete" and "op"(e_B) = "delete"$, { Return[$e_A$] })
        Comment[插入--插入冲突]
        If($"op"(e_A) = "insert" and "op"(e_B) = "insert" and "text"(e_A) = "text"(e_B)$, { Return[$e_A$] })
        If($"op"(e_A) = "insert" and "op"(e_B) = "insert"$, { Return[("conflict")] })
        Comment[移动--移动冲突]
        If($"op"(e_A) = "move" and "op"(e_B) = "move" and "dest"(e_A) = "dest"(e_B)$, { Return[$e_A$] })
        Return[("conflict")]
      },
    )
  },
) <algo:merge-decision>

== 文本渲染

渲染步骤将合并后的编辑序列转换为最终的文本输出。本实验提供两条渲染路径。

简单路径适用于不涉及移动编辑的场景。该路径将接受的可应用编辑，包括更新、删除、插入，转化为带起止偏移的 TextOp 文本操作，按从文本末尾到开头的逆序依次替换原始版本 $O$ 的源文本。逆序处理避免了因偏移量变化导致的位置计算错误。冲突区域渲染为标准的 diff3 标记。

结构化路径适用于包含移动编辑的一般场景。该路径以主导版本的依存树为导览，由移动编辑的方向决定，按表层顺序递归遍历，将来自非主导版本的编辑交织到遍历过程中。每个节点的遍历顺序为：先将前置子节点，即表层上位于该节点之前的子节点，递归渲染，然后渲染头节点本身，若存在更新编辑则覆盖为更新后的词形，最后渲染后置子节点。渲染过程中跳过已被删除的节点，遇到即时冲突节点时直接输出 diff3 标记块。

#algorithm-figure(
  [结构化重排渲染的子树遍历],
  supplement: [算法],
  vstroke: .5pt + luma(200),
  {
    import algorithmic: *
    Function(
      "Render-Subtree",
      ($n$, $T$),
      {
        Comment[即时冲突节点：直接渲染冲突块]
        If($"HasConflict"(n)$, { Return[$"ConflictBlock"(n)$] })
        Comment[拆分为前置组与后置组]
        Assign[$G_"pre"$][$"BeforeHead"(n, T)$]
        Assign[$G_"post"$][$"AfterHead"(n, T)$]
        Assign[$R$][""]
        Comment[前置子节点]
        For([$c in G_"pre"$], {
          If($"not"("Deleted"(c))$, {
            Assign[$R$][$R + "Render-Subtree"(c, T)$]
          })
        })
        Comment[头节点（含更新覆盖）]
        Assign[$R$][$R + "EmitHead"(n)$]
        Comment[后置子节点]
        For([$c in G_"post"$], {
          If($"not"("Deleted"(c))$, {
            Assign[$R$][$R + "Render-Subtree"(c, T)$]
          })
        })
        Return[$R$]
      },
    )
  },
) <algo:structured-render>

= 编码实现

本实验的代码以 Python 包的形式组织在 semdiff3 项目中。semdiff3 需要 Python 3.14 及以上版本，主要依赖包括 Stanza，用于依存句法分析；edist，用于 Zhang-Shasha 树编辑距离计算；Typer，用于命令行界面；以及 Rich，用于日志与格式化输出。项目以 uv 作为包管理器，采用 src 布局，测试框架使用 pytest。各模块与流水线步骤的对应关系如@table:modules 所示。

#tbl(
  table(
    columns: 3,
    stroke: none,
    table.hline(),
    table.header([模块], [流水线步骤], [核心职责]),
    table.hline(stroke: 0.5pt),
    ["tree.py"], [数据结构], [SemanticNode、SemanticTree 的定义],
    ["parsing.py"], [步骤 1], [Stanza UD 流水线封装],
    ["canon.py"], [步骤 2], [CanonicalTree 生成、子节点排序],
    ["matching.py"], [步骤 3], [自顶向下与自底向上两阶段匹配],
    ["equiv.py"], [步骤 4], [ClassMap 构建、一致性校验],
    ["diff.py"], [步骤 5], [Update/Move/Insert/Delete 编辑生成],
    ["merge.py"], [步骤 6], [决策表、四种冲突检测],
    ["render/simple.py"], [步骤 7a], [基于逆偏移文本替换的简单渲染],
    ["render/structured.py"], [步骤 7b], [基于导览树行走的结构化重排],
    ["cli.py"], [命令行], [Typer CLI、dev 系列命令],
    table.hline(),
  ),
  caption: [semdiff3 模块与流水线步骤对应关系],
) <table:modules>

其中 matching.py 为最大的模块，约 650 行，实现了结构键定义、Dice 系数计算、Zhang-Shasha 树编辑距离封装等核心逻辑。merge.py 约 200 行，实现了决策表的主控逻辑和四种冲突类型的检测与构造。render 目录包含两个渲染器，simple.py 适用于无词序变化的场景，structured.py 则通过递归的子树遍历处理含词序变化的场景。

命令行界面提供了完整的流水线调试支持。`prep-stanza` 命令用于预下载 Stanza 模型。`dev-parse`、`dev-canonicalize`、`dev-match`、`dev-classmap`、`dev-diff`、`dev-merge`、`dev-simple-render` 和 `dev-structured-render` 分别对应流水线的各个步骤，支持逐步观察中间结果。每个命令均支持 `--verbose` 选项以输出调试级别的日志。

= 效果评价

== 评价方法

在实现正确性方面，本实验使用大型语言模型辅助编写针对每个流水线阶段的单元测试，共编写 109 个测试函数，覆盖了规范化、匹配、等价类构建、差异计算、合并及渲染六个模块的各类编辑场景，使用 Pytest@pytest 收集覆盖率。对于端到端试验与效果评价，本实验同样借助大语言模型辅助构建十余条自然语言测试用例。

== 实验结果

餐厅场景三个版本的文本及编辑性质如@table:restaurant-versions 所示。

#tbl(
  table(
    columns: 3,
    stroke: none,
    table.hline(),
    table.header([版本], [文本], [编辑性质]),
    table.hline(stroke: 0.5pt),
    [$O$], [I drove to the restaurant in the afternoon.], [原始版本],
    [$A$], [I drove to the restaurant in the morning.], [Update: afternoon #sym.arrow.r morning],
    [$B$], [In the afternoon, I drove to the restaurant.], [Move: 时间状语前移],
    table.hline(),
  ),
  caption: [餐厅场景的版本信息],
) <table:restaurant-versions>

针对该用例，semdiff3 对各节点的编辑解析与合并结果如@table:restaurant-resolution 所示。

#tbl(
  table(
    columns: 5,
    stroke: none,
    table.hline(),
    table.header([$O$ 节点], [$A$ 编辑], [$B$ 编辑], [解析], [解析度]),
    table.hline(stroke: 0.5pt),
    [drove], [], [], [双侧无编辑], [identical],
    [afternoon], [Update], [], [接受 $A$ 的更新], [one_sided],
    [afternoon 位置], [], [Move], [接受 $B$ 的前移], [one_sided],
    [逗号插入], [], [Insert], [接受 $B$ 的插入], [one_sided],
    table.hline(),
  ),
  caption: [餐厅场景的编辑解析与合并结果],
) <table:restaurant-resolution>

#img(
  image("assets/demo-restaurant-case.png"),
  caption: [餐厅场景的端到端合并演示],
) <figure:demo-restaurant-case>

如@figure:demo-restaurant-case 所示，最终合并输出为“In the morning, I drove to the restaurant.”，合并状态为 clean。这一结果验证了本方法的核心设计：Alice 的 Update 内容更新与 Bob 的 Move 语序调整作用于不同的维度，通过决策表正确组合，产生了符合预期的合并结果。

除餐厅场景之外，semdiff3 还在以下场景中取得了干净的合并结果。两侧对同一个词进行不同内容更新时，若匹配正确则报告 UpdateUpdate 冲突；两侧对不同词进行更新时，合并干净地完成。此外，对于一侧进行插入、另一侧进行更新，或一侧进行删除、另一侧不做改动的单侧编辑场景，semdiff3 均能正确地将编辑合并到最终文本中。

多词短语的合并效果良好。例如 $O$ 为“The large blue car stopped.”，$A$ 将“blue”改为“red”，$B$ 将“car”改为“bus”，semdiff3 正确合并为“The large red bus stopped.”。对于包含从句的复句，如“Although it was freezing, we went outside.”，semdiff3 能够正确处理从句与主句的关系。

当两侧编辑确实无法共存时，semdiff3 正确地将冲突检测出来并渲染为 diff3 标记。典型的冲突场景包括以下四种类型。当两侧同时将同一个词更新为不同的内容时产生更新--更新冲突。当一侧删除一个词而另一侧对其进行修改时产生删除--更新冲突。当两侧在相同位置插入不同的词时产生插入--插入冲突。当两侧以不兼容的方式调整同一个节点的词序时产生移动--移动冲突，如@figure:demo-conflict 所示。

#img(
  image("assets/demo-conflict.png"),
  caption: [插入--插入冲突的端到端合并演示],
) <figure:demo-conflict>

= 结论与后续工作

本实验实现并验证了基于依存句法树的三路语义合并方法。通过将自然语言的树形结构分解为依存三元组与顺序三元组两个正交维度，并采用 GumTree 风格的两阶段匹配以及基于决策表的合并策略，semdiff3 能够正确融合包含语序调整与词汇替换的复合编辑。两维度分解，即将依存关系与表层词序分离，是本方法的核心思路。这一分离使得更新编辑与移动编辑可以组合共存，而不必像行级合并那样将二者混为一谈。在餐厅场景中，Alice 的内容更新与 Bob 的语序调整分别作用于不同的维度，决策表正确地将二者组合为“In the morning, I drove to the restaurant.”，验证了结构感知合并方法在自然语言领域的有效性。

在实现过程中，树匹配参数的调优对合并质量有显著影响。Dice 阈值设为 0.5 时，在匹配的精确率与召回率之间取得了较好的平衡。阈值过低会导致错误的编辑分类，将本应冲突的编辑误判为干净合并；阈值过高则会产生可避免的冲突，使许多可以自动处理的编辑被推送给用户。依存句法分析的精度直接决定了下游合并质量的上限。Stanza 解析器对大部分句式能够给出合理的分析结果，但在复杂句式上，例如嵌套从句、特殊疑问句，偶尔会出现分析错误，这些错误会直接传播至匹配阶段并导致错误的节点对齐。Stanza 同样无法处理混合语言的情况，除模型主语言之外的外语均会以无结构线性列表形式返回，失去了依存结构。最后，二元 Jaccard 相似度作为集合相似度算法，其对词的特异性较弱。

后续工作可从以下几个方面展开。第一，实现多句文档的完整处理流水线，包括分句、对齐、逐句路由和重组；第二，探索使用词嵌入与向量空间内的相似度指标对叶子节点进行对齐；第三，收集更多测试素材并进行更广泛的基准测试与比较，尤其是与目前基于大语言模型推理等较优方案进行对比与分析。

= 源代码

本实验完整源代码可从 #link("https://github.com/CSharperMantle/semdiff3") 获取。

#pagebreak()

#bibliography("bib.bib", style: "gb-7714-2015-numeric")
