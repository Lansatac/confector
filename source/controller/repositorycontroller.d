module controller.repositorycontroller;
import vibe.vibe;


URLRouter repositoryRouter()
{
	auto repositoryRouter = new URLRouter("/repositories");
	repositoryRouter.registerWebInterface(new RepositoryController);
  return repositoryRouter;
}

class RepositoryController
{

  void index()
  {
    string[] repositories = [];
    render!("repositories.dt", repositories);
  }
  
  void getAddRepo()
  {
    render!("add-repo.dt");
  }
}