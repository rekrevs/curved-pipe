%NTB 2024
%Read and plot data from Schubert_Fortran66_1972.f
%

clc
clear all
close all

%default
graphics_toolkit ("qt")

%graphics_toolkit ("gnuplot")
%graphics_toolkit ("fltk")

%Figure settings (Nils's blindeskrift)
set(0,'defaultlinelinewidth',2);
set(0,'defaultaxeslinewidth',1);
set(0,'defaulttextfontsize',14); %14
set(0,'defaultaxesfontsize',8); %14

addpath('C:\Users\nilsba\OneDrive - RISE\NTB\projects\Non-funded\Fortran66\Schubert_Fortran66_1972\sign_changes')

no_preamble_lines=7
%10 100 250 500 1000 2000 5000
D=10

%0 original
%1 updated
sel_case=1

D_str=int2str(D);
if sel_case==0
  filename = ['original_file_D' D_str '.dat']
end
if sel_case==1
  filename = ['updated_file_D' D_str '.dat']
end
fid = fopen(filename);
textLine = fgets(fid); % Read first line.
lineCounter = 1;
while ischar(textLine)
  %  fprintf('\nLine #%d of text = %s\n', lineCounter, textLine);
  % get into numbers array.
  numbers = sscanf(textLine, '%f ');
  % Put numbers into a cell array IF and only if
  % you need them after the loop has exited.
  % First method - each number in one cell.
  for k = 1 : length(numbers)
    ca{lineCounter, k} = numbers(k);
  end
  % ALternate way where the whole array is in one cell.
  ca2{lineCounter} = numbers;

  % Read the next line.
    textLine = fgets(fid);
  lineCounter = lineCounter + 1;
end
fclose(fid);
% Display the cell arrays in the command line.
%ca
%ca2
NRP1=ca{1,1}
NAP1=ca{2,1}
XI=cell2mat(ca(3,1:4))
RHO=cell2mat(ca(4,1:3))
EPS=cell2mat(ca(5,1:3))
QR=ca{7,1}
%arrays
PHI=zeros(NRP1,NAP1);
W=zeros(NRP1,NAP1);
OMEGA=zeros(NRP1,NAP1);
%
temp1=size(ca);
ca_red=ca(no_preamble_lines+1:temp1(1),:);
temp2=size(ca_red);
rows_per_array=(temp2(1))/3;
ca_PHI=ca_red(1:rows_per_array,:);
ca_W= ca_red(rows_per_array+1:2*rows_per_array,:);
ca_OMEGA=ca_red(2*rows_per_array+1:3*rows_per_array,:);
%
PHI=cell2mat(ca_PHI);
W=cell2mat(ca_W);
OMEGA=cell2mat(ca_OMEGA);

r=0:1/(NRP1-1):1;
alpha=0:pi/(NAP1-1):pi;

[alpha_grid,r_grid]=meshgrid(alpha,r);
% Convert to Cartesian
x = r_grid.*cos(alpha_grid);
y = r_grid.*sin(alpha_grid);

if sel_case==0
  titlestr=['D = ' D_str, ' [original]'];
end
if sel_case==1
  titlestr=['D = ' D_str, ' [updated]'];
end

no_levels=25

f1=figure(1)
h = polar(x,y);
set(h,'Visible','off')
hold on;
contourf(x,y,PHI,no_levels);
contourf(x,-y,-PHI,no_levels);
%xlabel('Radius')
%ylabel('Angle')
title(titlestr)
axis equal;
colormap(jet(256));
col=colorbar;
caxis(col,[0,max(max(PHI))]);
title(col,'{\Phi}');
savestr_png=[titlestr ', PHI.png'];
saveas (f1, savestr_png);
%print -color -depsc PHI.eps
'Min PHI:'
min(min(PHI))
'Max PHI:'
max(max(PHI))

f2=figure(2)
h = polar(x,y);
set(h,'Visible','off')
hold on;
contourf(x,y,W,no_levels);
contourf(x,-y,W,no_levels);
%xlabel('Radius')
%ylabel('Angle')
title(titlestr)
axis equal;
colormap(jet(256));
col=colorbar;
caxis(col,[0,max(max(W))]);
title(col,"W");
savestr=[titlestr ', W.png'];
saveas (f2, savestr);
%print -color -depsc W.eps
'Min W:'
min(min(W))
'Max W:'
maxW = max(max(W))
[x_maxW,y_maxW]=find(W==maxW);
%to handle D=10:
single_x_maxW = x_maxW(1);
single_y_maxW = y_maxW(1);
%
r_maxW = sqrt(x(single_x_maxW,single_y_maxW).^2+y(single_x_maxW,single_y_maxW).^2)
alpha_maxW = atand(y(single_x_maxW,single_y_maxW)/x(single_x_maxW,single_y_maxW));
if isnan(alpha_maxW)==1
  alpha_maxW=0.0;
endif
alpha_maxW

f3=figure(3)
h = polar(x,y);
set(h,'Visible','off')
hold on;
contourf(x,y,OMEGA,no_levels);
contourf(x,-y,-OMEGA,no_levels);
%xlabel('Radius')
%ylabel('Angle')
title(titlestr)
axis equal;
colormap(jet(256));
col=colorbar;
caxis(col,[min(min(OMEGA)),max(max(OMEGA))]);
title(col,'{\Omega}');
savestr=[titlestr ', OMEGA.png'];
saveas (f3, savestr);
%print -color -depsc OMEGA.eps
'Min OMEGA:'
min(min(OMEGA))
'Max OMEGA:'
max(max(OMEGA))

%saveas(gca,'fluc_sq_norm_AA_and_CL.eps','epsc');


