" =============================================================================
" Basic Settings
" =============================================================================
set nocompatible              " Use Vim settings, not Vi
filetype plugin indent on     " Enable filetype detection and plugins
syntax enable                 " Enable syntax highlighting

" =============================================================================
" Display
" =============================================================================
set number                    " Show line numbers
set relativenumber            " Relative line numbers
set cursorline                " Highlight current line
set showcmd                   " Show command in bottom bar
set showmode                  " Show current mode
set showmatch                 " Highlight matching brackets
set wildmenu                  " Visual autocomplete for command menu
set wildmode=longest:full,full
set laststatus=2              " Always show status line
set ruler                     " Show cursor position
set scrolloff=5               " Keep 5 lines above/below cursor
set sidescrolloff=5           " Keep 5 columns left/right of cursor
set display+=lastline         " Show as much as possible of last line
set linebreak                 " Break lines at word boundaries
set wrap                      " Wrap long lines

" =============================================================================
" Colors
" =============================================================================
set background=dark
set termguicolors             " Enable true colors if supported

" =============================================================================
" Search
" =============================================================================
set hlsearch                  " Highlight search results
set incsearch                 " Show matches as you type
set ignorecase                " Case insensitive search
set smartcase                 " Unless uppercase is used

" Clear search highlighting with Escape
nnoremap <Esc> :nohlsearch<CR>

" =============================================================================
" Indentation
" =============================================================================
set autoindent                " Copy indent from current line
set smartindent               " Smart autoindenting
set expandtab                 " Use spaces instead of tabs
set tabstop=4                 " Tab = 4 spaces
set shiftwidth=4              " Indent = 4 spaces
set softtabstop=4             " Backspace through spaces like tabs
set smarttab                  " Smart tab handling

" =============================================================================
" Editing
" =============================================================================
set backspace=indent,eol,start  " Make backspace work properly
set mouse=a                   " Enable mouse support
set ttymouse=sgr              " Better mouse support (handles large terminals)
if !empty($SSH_CONNECTION)
    set clipboard=              " Disable system clipboard over SSH (use tmux instead)
else
    set clipboard=unnamed       " Use system clipboard locally
endif
set hidden                    " Allow hidden buffers
set autoread                  " Auto reload changed files
set encoding=utf-8            " UTF-8 encoding
set fileencoding=utf-8

" =============================================================================
" Files & Backup
" =============================================================================
set nobackup                  " Don't create backup files
set nowritebackup
set noswapfile                " Don't create swap files
set undofile                  " Persistent undo
set undodir=~/.vim/undo       " Undo directory

" Create undo directory if it doesn't exist
if !isdirectory($HOME . '/.vim/undo')
    call mkdir($HOME . '/.vim/undo', 'p', 0700)
endif

" =============================================================================
" Performance
" =============================================================================
set lazyredraw                " Don't redraw during macros
set ttyfast                   " Faster terminal connection
set updatetime=300            " Faster completion

" =============================================================================
" Key Mappings
" =============================================================================
" Set leader key to space
let mapleader = " "

" Quick save
nnoremap <leader>w :w<CR>

" Quick quit
nnoremap <leader>q :q<CR>

" Better window navigation
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" Move lines up/down
nnoremap <A-j> :m .+1<CR>==
nnoremap <A-k> :m .-2<CR>==
vnoremap <A-j> :m '>+1<CR>gv=gv
vnoremap <A-k> :m '<-2<CR>gv=gv

" Keep visual selection when indenting
vnoremap < <gv
vnoremap > >gv

" Y yanks to end of line (like D and C)
nnoremap Y y$

" Center screen after jumps
nnoremap n nzzzv
nnoremap N Nzzzv
nnoremap <C-d> <C-d>zz
nnoremap <C-u> <C-u>zz

" Quick buffer navigation
nnoremap <leader>bn :bnext<CR>
nnoremap <leader>bp :bprevious<CR>
nnoremap <leader>bd :bdelete<CR>

" =============================================================================
" Status Line
" =============================================================================
set statusline=
set statusline+=%#PmenuSel#
set statusline+=\ %f              " File path
set statusline+=\ %m              " Modified flag
set statusline+=%=                " Right align
set statusline+=\ %y              " File type
set statusline+=\ %{&fileencoding?&fileencoding:&encoding}
set statusline+=\ [%{&fileformat}]
set statusline+=\ %l:%c           " Line:Column
set statusline+=\ %p%%            " Percentage
set statusline+=\

" =============================================================================
" Filetype Specific
" =============================================================================
" 2-space indent for certain filetypes
autocmd FileType html,css,javascript,typescript,json,yaml,vue setlocal tabstop=2 shiftwidth=2 softtabstop=2

" Enable spell checking for text files
autocmd FileType markdown,text setlocal spell spelllang=en_us
