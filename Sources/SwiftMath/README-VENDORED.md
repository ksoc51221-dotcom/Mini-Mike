SwiftMath 1.7.3 (https://github.com/mgriebling/SwiftMath), MIT, see LICENSE.
Vendored without changes except: font lookup goes through MathFontLocator (Bundle.main Resources/Fonts) instead of Bundle.module
(MathBundle/MathFont.swift, MathRender/MTFont.swift). Only Latin Modern Math is shipped (Resources/Fonts, GUST font licence beside it).
